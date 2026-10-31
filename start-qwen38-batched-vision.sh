#!/bin/bash
# Qwen3.8-Flash-Next — MULTI-CLIENT VISION profile: N resident sessions, native 262k, mmproj on.
#
#   Default: SESSIONS=2  CTX=262144  KV_GB=240
#   Three clients:  SESSIONS=3 ./start-qwen38-batched-vision.sh
#   Speculation off: MTP_FLAG= ./start-qwen38-batched-vision.sh
#   Less disk budget: KV_GB=120 ./start-qwen38-batched-vision.sh
#
# WHY THIS SCRIPT EXISTS
#   start-qwen38-262k-vision.sh keeps ONE resident session, so two vision clients
#   evict each other's live KV on every turn — the same failure the text profile
#   showed on 2026-10-29 (`live kv cache miss ... common=6897`, then a full
#   re-prefill). This script is that profile plus --batched-session N, so the
#   router pins each client to the slot it can reuse (job_slot_score, and an
#   ACTIVE peer slot is the last eviction victim).
#
# WHAT BATCHING DOES NOT COST YOU HERE
#   MTP survives: qwen4_batch_mtp = Metal + qwen4 + draft>1 (ds4_server.c:15999),
#   and the "MTP speculative decoding is disabled while native session batching is
#   active" line only prints when that is false (ds4_server.c:16056).
#
# WHAT VISION DOES COST YOU  (docs/QWEN38_FLASH_NEXT.md:51-62)
#   1. "images ... use the ordered fallback". A request that carries an image
#      decodes in order, not in the shared batch, so the batched weight-read win
#      lands on the TEXT turns of both sessions and not on the image turn. Two
#      vision sessions still stop the re-prefill, which was the whole loss.
#   2. Grouping reorders floating-point reductions, so a batched reply can differ
#      from the same prompt decoded alone.
#   3. Image requests never take the prompt-tail checkpoint path: kv_cache_maybe_store_
#      prompt_tail bails on req->image_count. The near-tail pool therefore holds each
#      session's TEXT frontiers, which is what patch 0009 sizes.
#   4. Image state is part of the checkpoint and is fingerprint-checked
#      (ds4_session_vision_prefix_matches, ds4_session_vision_fingerprint_prefix_
#      matches). Patch 0006 keys the vision embedding cache on the pixel fingerprint,
#      so a reused embedding cannot come from a different image.
#
# MEMORY — MEASURED ON THIS BOX, NOT GUESSTIMATED
#   The single-session 262k vision server right now: RSS 89,038,272 KiB = 84.9 GiB
#   (ps, 2026-10-31). KV for a full 262144 slot = 8.33 GiB (vault capture
#   Reference/m5-max-128gb-ds4-qwen38-flash-next-perf.md). Slots share one prefill
#   workspace (share_session_prefill_workspace), so the second slot costs its caches,
#   not another workspace: expect roughly 93-95 GiB. The wired limit is set to
#   118784 MiB (116 GiB). Read the server's own line before you trust this:
#     ds4-server: 2 resident sessions request at least X GiB ... or Y GiB when the
#                  model shares one prefill workspace
#   If it will not fit, drop KV_GB before you drop CTX — context is the useful axis.
#     sudo sysctl iogpu.wired_limit_mb=118784      # RESETS ON REBOOT
#
# KV DISK TIER
#   1. Native 262k with NO YaRN is the same rope profile start-qwen38-262k-vision.sh
#      writes, so it shares its --kv-disk-dir on purpose: checkpoints carry over
#      instead of being rebuilt. Never mix a YaRN run into this dir — the checkpoint
#      header has no rope field and the ctx filter is one-directional, so the load
#      succeeds and the attention runs in the wrong rotary frame, silently
#      (docs/KV_PROFILE_ISOLATION.md §1-4).
#   2. --kv-cache-cold-max-tokens follows CTX. The 2026-10-31 live invocation carried
#      393216 against --ctx 262144, a leftover from the YaRN profile; that asks the
#      cold path for checkpoints wider than the context can hold.
#   3. The near-tail pool is min(budget/8, 16 GiB x sessions) — kv_cache_tail_budget
#      (pr1200) as resized by our patch 0009. A 262k checkpoint is ~8.3 GiB, so at
#      KV_GB=240 the pool is min(30, 32) = 30 GiB and holds both sessions' frontiers
#      with room to spare; at KV_GB=120 it is min(15, 32) = 15 GiB and holds one.
#
# Only ONE ds4-server runs on this machine — never start this alongside
# start-qwen38-batched.sh, start-qwen38-longctx.sh or start-qwen38-262k-vision.sh.

set -euo pipefail
cd "$(dirname "$0")"

CTX="${CTX:-262144}"
YARN="${YARN:-1}"
PORT="${PORT:-8080}"
SESSIONS="${SESSIONS:-2}"
KV_GB="${KV_GB:-240}"
KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache}"
MODEL="${MODEL:-$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf}"
MMPROJ="${MMPROJ:-$HOME/repos/ds4/gguf/mmproj-Qwen3.8-Flash-Next-Q8_0.gguf}"
MTP_FLAG="${MTP_FLAG:---mtp --mtp-timing}"   # --mtp-timing prints acceptance counters

if [ "$SESSIONS" -lt 1 ]; then
  echo "refusing: SESSIONS=$SESSIONS — use 1 or more (1 is the old single-session behaviour)" >&2
  exit 1
fi
# Guard: native 262k must not carry a rope factor. YaRN rescales the rotary
# frequencies for ALL positions (ds4.c:6976-7002) and the checkpoint header has no
# rope field, so YaRN-on-262k writes a third frame into a dir other servers read as
# native.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 <= 262144 && y+0 > 1.0) }'; then
  echo "refusing: ctx $CTX is native but YARN=$YARN > 1 — that writes a third rotary frame into $KV_DIR" >&2
  echo "          for a native-context run use YARN=1; for a YaRN run use start-qwen38-batched.sh with its own --kv-disk-dir" >&2
  exit 1
fi
# Guard: above native you need a real factor, and this script's dir is the native one.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 <= 1.0) }'; then
  echo "refusing: ctx $CTX > native 262144 with YARN=$YARN — would silently degrade past 262k" >&2
  exit 1
fi
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 > 1.0) }'; then
  echo "refusing: ctx $CTX with YARN=$YARN is a YaRN profile, and $KV_DIR is the native-262k dir" >&2
  echo "          use start-qwen38-batched.sh, or point KV_DIR at a dir no other profile writes" >&2
  exit 1
fi
[ -f "$MMPROJ" ] || { echo "refusing: mmproj not found: $MMPROJ" >&2; exit 1; }

WIRED=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
if [ "${WIRED:-0}" -eq 0 ]; then
  echo "WARNING: iogpu.wired_limit_mb is unset (macOS default ~75% of RAM ~96 GiB)."
  echo "         ${SESSIONS} slots at ctx $CTX plus one 84.9 GiB baseline may not fit."
  echo "           sudo sysctl iogpu.wired_limit_mb=118784"
fi

# YaRN is only exported when it is actually a factor, so a native run leaves the
# engine's own default in place instead of pinning a value another profile reads.
if awk -v y="$YARN" 'BEGIN { exit !(y+0 > 1.0) }'; then export DS4_QWEN4_YARN_FACTOR="$YARN"; fi

echo "ds4 batched-vision: ctx=$CTX yarn=$YARN sessions=$SESSIONS kv=${KV_GB}GiB dir=$KV_DIR port=$PORT"
echo "                    model=$(basename "$MODEL") mmproj=$(basename "$MMPROJ")"
echo "wired_limit_mb=${WIRED:-unset}  mtp='${MTP_FLAG}'"
if [ "$KV_DIR" = "$HOME/.ds4/kv-cache" ]; then
  echo "NOTE: $KV_DIR is shared with start-qwen38-262k-vision.sh on purpose (same native"
  echo "      rope profile, so checkpoints carry over). Keep every YaRN profile out of it."
fi
if [ "$SESSIONS" -gt 16 ]; then
  echo "note: SESSIONS=$SESSIONS > 16 also drops speculation to the ordered fallback"
fi
echo
echo 'VERIFY AFTER START (two clients, alternating, at least one carrying an image):'
echo '  1. startup prints "batched mode enabled resident_sessions='"$SESSIONS"'"'
echo '  2. no "MTP speculative decoding is disabled while native session batching is active"'
echo '  3. read the "resident sessions request at least ... GiB" line against 116 GiB'
echo '  4. a client switch shows "kv cache hit text" + a small prefill, NOT "discarding and healing"'
echo '  5. "live kv cache miss ... common=6897" stops appearing while both clients stay active'
echo
echo 'watch memory:   ps -o rss= -p $(pgrep -f ds4-server) | awk '"'"'{printf "RSS %.1f GB\n", $1/1048576}'"'"''
echo 'watch routing:  grep -E "live kv cache miss|resident sessions|kv cache (hit|stored|evicted|discarded)"'

exec ./ds4-server \
  --ctx "$CTX" \
  --batched-session "$SESSIONS" \
  --port "$PORT" --host 0.0.0.0 --cors \
  -m "$MODEL" \
  --vision "$MMPROJ" \
  ${MTP_FLAG:+$MTP_FLAG} \
  --warm-weights \
  --prefill-chunk 8192 \
  --tool-memory-max-ids 32768 \
  --kv-disk-dir "$KV_DIR" \
  --kv-disk-space-mb "$((KV_GB * 1024))" \
  --kv-cache-min-tokens 4096 \
  --kv-cache-cold-max-tokens "$CTX" \
  --kv-cache-continued-interval-tokens 32768 \
  --kv-cache-reject-different-quant
