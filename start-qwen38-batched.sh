#!/bin/bash
# Qwen3.8-Flash-Next — MULTI-CLIENT profile: N resident sessions, YaRN-extended, text-only.
#
#   Default: SESSIONS=2  CTX=393216  YARN=1.5  KV_GB=240
#   Three clients:  SESSIONS=3 ./start-qwen38-batched.sh
#   Speculation off: MTP_FLAG= ./start-qwen38-batched.sh
#
# WHY THIS SCRIPT EXISTS
#   Without --batched-session the server keeps ONE resident session (docs/SERVER.md:58).
#   Two clients then evict each other's live KV on every turn: the log shows
#   `live kv cache miss ... common=6897` (the shared system+tool prefix only) and a
#   full re-prefill — 436 s for 307,066 tokens on 2026-10-29. With N slots the
#   router pins each client to the slot it can reuse: job_slot_score (ds4_server.c)
#   scores a slot by its reusable prefix and makes an ACTIVE peer slot the last
#   eviction victim (SLOT_STALE_AFTER_SEC = 1 h). Same evidence says decode is fine
#   (34 t/s at 334k ctx) — the loss was always the cache, not the math.
#
# WHAT --batched-session DOES NOT COST
#   MTP survives on this box: qwen4_batch_mtp = Metal + qwen4 + draft>1
#   (ds4_server.c:15999), and the "MTP disabled while batching" warning only prints
#   when it is false (:16056). docs/QWEN38_FLASH_NEXT.md:51-62 confirms native
#   Qwen3.8 batching plus batched speculation. Two caveats from the same doc:
#   grouping reorders floating-point reductions, so a batched reply can differ from
#   the same prompt decoded alone; and images/steering/speculation past 16 sessions
#   fall back to ordered execution. This profile runs no vision encoder.
#
# DO NOT TOUCH --prefill-chunk FOR THIS
#   It is also the prefill batch cap (ds4_prefill_cap_for_prompt, ds4.c:14303), so a
#   smaller chunk slows every rebuild by the same factor it raises store frequency.
#   docs/KV_PROFILE_ISOLATION.md:130-134.
#
# MEMORY — CHECK BEFORE THE FIRST RUN
#   Slots share one prefill workspace on this model (share_session_prefill_workspace,
#   ds4_server.c:15917), so an added slot costs only its caches. The server prints the
#   plan at startup — read this line before you trust it:
#     ds4-server: 2 resident sessions request at least X GiB ... or Y GiB when the
#                  model shares one prefill workspace
#   Estimate from ONE measured point (KV 8.33 GiB at 262144, vault capture
#   Reference/m5-max-128gb-ds4-qwen38-flash-next-perf.md): ~12.5 GiB per added slot at
#   393216. One 393k server measured 83 GB real, so 2 slots land near the DEFAULT GPU
#   wired cap (sysctl iogpu.wired_limit_mb = 0 -> ~75% of 128 GiB ~ 96 GiB). Raise it:
#     sudo sysctl iogpu.wired_limit_mb=118784      # ~116 GiB to the GPU; RESETS ON REBOOT
#   If the second slot will not fit, run 2 slots at CTX=262144 instead of 1 at 393216.
#
# KV DISK TIER — TWO THINGS THE BUDGET DOES NOT BUY
#   1. The near-tail pool is capped independently: min(budget/8, 16 GiB per
#      resident session) — kv_cache_tail_budget, pr1200 as resized by our patch
#      0009. Before 0009 the cap was a flat 16 GiB, and a 393k checkpoint is
#      ~12.3 GiB (KV_PROFILE_ISOLATION.md §5), so the pool could never hold two
#      393k anchors at any budget. At 240 GiB with 2 sessions it is now
#      min(30, 32) = 30 GiB, which fits both. Patch 0007 also persists the
#      departing frontier under `reason=evict`, an anchor the tail prune never
#      touches, so the two patches cover each other's gap.
#   2. One --kv-disk-dir per rope profile (BUILD_PATCHES.md §Do-not list). This dir
#      holds 393k + YaRN 1.5 checkpoints only. Never point a 262k / no-YaRN server at
#      it: the header has no rope field and the ctx filter is one-directional, so the
#      load succeeds and the attention runs in the wrong rotary frame, silently.
#
# Only ONE ds4-server can run on this machine — do not start this alongside the
# 262k-vision or longctx launchers.

set -euo pipefail
cd "$(dirname "$0")"

CTX="${CTX:-393216}"
YARN="${YARN:-1.5}"
PORT="${PORT:-8080}"
SESSIONS="${SESSIONS:-2}"
KV_GB="${KV_GB:-240}"
KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache}"
MTP_FLAG="${MTP_FLAG:---mtp --mtp-timing}"   # --mtp-timing prints acceptance counters

# Guard: above native you must have a real factor, or you silently degrade past 262k.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 <= 1.0) }'; then
  echo "refusing: ctx $CTX > native 262144 with YARN=$YARN — would silently degrade past 262k" >&2
  exit 1
fi
if [ "$SESSIONS" -lt 1 ]; then
  echo "refusing: SESSIONS=$SESSIONS — use 1 or more (1 is the old single-session behaviour)" >&2
  exit 1
fi
# Guard: a native-context run must not carry a rope factor. YaRN rescales the
# rotary frequencies for ALL positions (ds4.c:6976-7002), and a checkpoint header
# has no rope field (docs/KV_PROFILE_ISOLATION.md §1-3), so YaRN-on-262k would
# write entries that a YaRN-off 262k server cannot tell apart from its own.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 <= 262144 && y+0 > 1.0) }'; then
  echo "refusing: ctx $CTX is native but YARN=$YARN > 1 — that writes a third rotary frame into $KV_DIR" >&2
  echo "          for a native-context run use YARN=1, and give any YaRN run its own --kv-disk-dir" >&2
  exit 1
fi

WIRED=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
if [ "${WIRED:-0}" -eq 0 ]; then
  echo "WARNING: iogpu.wired_limit_mb is unset (macOS default ~75% of RAM ~96 GiB)."
  echo "         ${SESSIONS} slots at ctx $CTX may not fit. Raise it (resets on reboot):"
  echo "           sudo sysctl iogpu.wired_limit_mb=118784"
fi

export DS4_QWEN4_YARN_FACTOR="$YARN"
echo "ds4 batched: ctx=$CTX YaRN=$YARN sessions=$SESSIONS kv=${KV_GB}GiB dir=$KV_DIR port=$PORT (vision disabled)"
if [ "$KV_DIR" = "$HOME/.ds4/kv-cache" ]; then
  echo "NOTE: $KV_DIR is the dir start-qwen38-262k-vision.sh also uses (no YaRN). Do not run that"
  echo "      profile against this dir — same header, different rotary frame, silent wrong attention."
  echo "      Isolation rule and rename procedure: docs/KV_PROFILE_ISOLATION.md §4."
fi
echo "wired_limit_mb=${WIRED:-unset}  mtp='${MTP_FLAG}'"
if awk -v c="$CTX" 'BEGIN { exit !(c+0 < 393216) }'; then
  echo "note: ctx $CTX is below 393216 — max thinking will be silently served as 'high'"
fi
echo 'watch memory:   ps -o rss= -p $(pgrep -f ds4-server) | awk '"'"'{printf "RSS %.1f GB\n", $1/1048576}'"'"''
echo 'watch routing:  grep -E "live kv cache miss|resident sessions|reuses nothing|kv cache (hit|stored|evicted|discarded)"'
echo
echo 'VERIFY AFTER START (two clients, alternating):'
echo '  1. startup prints "batched mode enabled resident_sessions='"$SESSIONS"'"'
echo '  2. no "MTP speculative decoding is disabled while native session batching is active"'
echo '  3. a client switch shows "kv cache hit text" + a small prefill, NOT "discarding and healing"'
echo '  4. "live kv cache miss ... common=6897" stops appearing while both clients stay active'

exec ./ds4-server \
  --ctx "$CTX" \
  --batched-session "$SESSIONS" \
  --port "$PORT" --host 0.0.0.0 --cors \
  -m "$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf" \
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
