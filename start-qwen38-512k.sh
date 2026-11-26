#!/bin/bash
# Qwen3.8-Flash-Next — 512K profile: ONE resident session, YaRN 2.0, vision on.
#
#   Default: CTX=524288  YARN=2.0  SESSIONS=1  KV_GB=240
#   Try without images:  MMPROJ= ./start-qwen38-512k.sh
#   Try without speculation: MTP_FLAG= ./start-qwen38-512k.sh
#   Try without weight warming (more headroom, slower first turn): WARM= ./start-qwen38-512k.sh
#
# WHY YaRN 2.0 AND NOT 4.0
#   The model card: "natively supports context lengths of up to 262,144 tokens ...
#   if the typical context length for your application is 524,288 tokens, it would
#   be better to set factor as 2.0." YaRN here is STATIC (ds4.c:7086-7114, HF
#   _compute_yarn_parameters with beta_fast 32 / beta_slow 1, mscale 0.1*ln(f)+1),
#   which is what every open-source framework ships, and the card warns it costs
#   some quality on short text. Native context is 262,144 — read out of the GGUF
#   itself: qwen4exp.context_length = 262144.
#
# MEMORY — extrapolated from two measured points on THIS box, not from the card
#   Anchor A  ctx 262,144: KV 8.33 GiB, workspace 11.68 GiB, resident model 69.73 GiB
#            => 89.74 GiB planned (startup line), RSS 84.9 GiB measured
#            (Reference/m5-max-128gb-ds4-qwen38-flash-next-perf.md, start-qwen38-batched-vision.sh)
#   Anchor B  ctx 393,216: KV 12.50 GiB, workspace 13.68 GiB
#            => 95.91 GiB planned at 2 slots' shared workspace (same vault capture)
#   KV is linear in rows by construction (raw rows = ctx, compressed rows = ctx/4,
#   ds4.c:60277 n_block_cap = ctx/4 + 1), so 8.33 GiB x ctx/262144 is exact.
#   The workspace slope (16 KiB/token) is a two-point extrapolation — the server's
#   own "context buffers"/"resident sessions request at least" lines are the truth.
#   At 524,288: KV 16.66 + workspace 15.68 + model 69.73 = ~102 GiB planned.
#   Wired limit on this box: iogpu.wired_limit_mb=118784 = 116 GiB, RAM 128 GiB.
#   TWO SLOTS DO NOT FIT HERE: 2 x 16.66 + 15.68 + 69.73 = ~119 GiB > 116 GiB.
#
# KV DISK TIER — read this before you call a restart slow
#   1. This profile writes its OWN rope frame (factor 2.0). A checkpoint header
#      carries no rope field (docs/KV_PROFILE_ISOLATION.md §1-3), so this dir must
#      not be shared with the native 262k profiles or the 1.5 profiles. The guard
#      below refuses the native dir outright.
#   2. The per-turn near-tail pool is min(budget/8, 16 GiB x sessions)
#      (ds4_kvstore.c:1026-1031). At SESSIONS=1 the ceiling is 16 GiB and KV_GB
#      CANNOT raise it — the 16 GiB is a literal in the code. One 524,288-token
#      checkpoint is ~17.9 GiB (34 KB/token), so the per-turn frontier is over the
#      ceiling and will be refused: expect the refusal line, not a silent gap.
#      The cold path still uses the whole budget, so a restart can still load a
#      full-prompt checkpoint.
#   3. The mid-prefill ladder is expensive at this size: at the usual 32,768
#      interval a single cold rebuild writes 4.46M checkpoint tokens ≈ 145 GiB.
#      The default here is 131,072 (four rungs, ~43 GiB). 0 disables it outright
#      (ds4_kvstore.c:798).
#
# Only ONE ds4-server runs on this machine — never start this alongside
# start-qwen38-batched-vision.sh, start-qwen38-batched.sh or start-qwen38-longctx.sh.

set -euo pipefail
cd "$(dirname "$0")"

CTX="${CTX:-524288}"
YARN="${YARN:-2.0}"
PORT="${PORT:-8080}"
SESSIONS="${SESSIONS:-1}"
KV_GB="${KV_GB:-240}"
KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache-512k}"
MODEL="${MODEL:-$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf}"
MMPROJ="${MMPROJ-$HOME/repos/ds4/gguf/mmproj-Qwen3.8-Flash-Next-Q8_0.gguf}"
MTP_FLAG="${MTP_FLAG:---mtp --mtp-timing}"
WARM="${WARM---warm-weights}"
CONTINUED="${CONTINUED:-131072}"

# Guard: above native you must carry a real factor, or you silently degrade past 262k.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 <= 1.0) }'; then
  echo "refusing: ctx $CTX > native 262144 with YARN=$YARN — would silently degrade past 262k" >&2
  exit 1
fi
# Guard: a native run must not carry a factor, or its checkpoints are indistinguishable.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 <= 262144 && y+0 > 1.0) }'; then
  echo "refusing: ctx $CTX is native but YARN=$YARN > 1 — that writes a foreign rotary frame into $KV_DIR" >&2
  exit 1
fi
# Guard: this factor owns its own directory. Nothing else may write it.
if [ "$KV_DIR" = "$HOME/.ds4/kv-cache" ] || [ "$KV_DIR" = "$HOME/.ds4/kv-cache-1m" ]; then
  echo "refusing: KV_DIR=$KV_DIR belongs to another rope frame (factor $YARN writes its own)" >&2
  echo "          leave KV_DIR at its default, or point it at a dir no other profile writes" >&2
  exit 1
fi
if [ "$SESSIONS" -gt 1 ]; then
  KVALL=$(awk -v c="$CTX" -v n="$SESSIONS" 'BEGIN { printf "%.1f", 8.33 * c / 262144.0 * n }')
  echo "WARNING: SESSIONS=$SESSIONS at ctx $CTX needs ~$KVALL GiB of KV before any workspace or weights." >&2
  echo "         Two slots at 524288 measure out to ~119 GiB against a 116 GiB wired limit." >&2
fi
[ -f "$MODEL" ] || { echo "refusing: model not found: $MODEL" >&2; exit 1; }
[ -z "$MMPROJ" ] || [ -f "$MMPROJ" ] || { echo "refusing: mmproj not found: $MMPROJ (use MMPROJ= for text only)" >&2; exit 1; }

WIRED=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
# Built as an array so a path with a space cannot split into two arguments.
VISION=()
[ -n "$MMPROJ" ] && VISION=(--vision "$MMPROJ")
PLAN=$(awk -v c="$CTX" 'BEGIN { kv = 8.33 * c / 262144.0; ws = 11.68 + (16.0/1048576.0) * (c - 262144.0); printf "%.1f", 69.73 + kv + ws }')
KVGIB=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 8.33 * c / 262144.0 }')
WSGIB=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 11.68 + (16.0/1048576.0) * (c - 262144.0) }')
WIREDBG=$(awk -v w="$WIRED" 'BEGIN { printf "%.0f", w / 1024.0 }')

echo "ds4 512k: ctx=$CTX yarn=$YARN sessions=$SESSIONS kv=${KV_GB}GiB dir=$KV_DIR port=$PORT"
echo "         model=$(basename "$MODEL") mmproj=$([ -n "$MMPROJ" ] && basename "$MMPROJ" || echo "text only")"
echo "         mtp='${MTP_FLAG}' warm='${WARM:-none}' continued=$CONTINUED"
awk -v kv="$KVGIB" -v ws="$WSGIB" -v p="$PLAN" -v w="$WIREDBG" 'BEGIN {
  printf "         plan %.1f GiB = 69.73 model + %.2f KV + %.2f workspace (extrapolated)\n", p, kv, ws
  printf "         wired limit %s GiB -> headroom %.1f GiB\n", w, w - p }'
if [ "${WIRED:-0}" -eq 0 ]; then
  echo "         WARNING: iogpu.wired_limit_mb is unset (macOS default ~96 GiB). Raise it (resets on reboot):"
  echo "           sudo sysctl iogpu.wired_limit_mb=118784"
fi
mkdir -p "$KV_DIR"
echo
echo 'VERIFY AFTER START:'
echo '  1. the memory line reads KV ~16.66 GiB and the plan lands near 102 GiB, not above the wired limit'
echo '  2. no "context ... exceeds the native 262144 tokens" warning (that means YaRN did not take)'
echo '  3. first long turn: "chat ctx=0..N" prefills at ~800 t/s and decode lands in the 20s-30s t/s band'
echo '  4. near-tail stores may be REFUSED at this size (16 GiB pool ceiling at SESSIONS=1) — read the'
echo '     refusal line, then check the cold store landed so a restart can still load'
echo
echo 'log it (server writes stderr, so tee alone captures nothing): ./start-qwen38-512k.sh >> ~/ds4-512k.log 2>&1'
echo 'watch memory:   ps -o rss= -p $(pgrep -f ds4-server) | awk '"'"'{printf "RSS %.1f GB\n", $1/1048576}'"'"''
echo 'watch routing:  grep -E "KV disk cache|context buffers|kv cache (hit|stored|evicted|refused)|exceeds the native"'
echo
echo 'sampling is the client'"'"'s job (the server takes temperature from each request).'
echo 'model card, thinking mode: temperature 1.0 top_p 0.95 top_k 20 min_p 0 presence_penalty 0 repetition_penalty 1'
echo 'model card, instruct mode: temperature 0.7 top_p 0.80 top_k 20 min_p 0 presence_penalty 1.5 repetition_penalty 1'

exec ./ds4-server \
  --ctx "$CTX" \
  --batched-session "$SESSIONS" \
  --port "$PORT" --host 0.0.0.0 --cors \
  -m "$MODEL" \
  ${VISION[@]+"${VISION[@]}"} \
  ${MTP_FLAG:+$MTP_FLAG} \
  ${WARM:+$WARM} \
  --prefill-chunk 8192 \
  --tool-memory-max-ids 32768 \
  --kv-disk-dir "$KV_DIR" \
  --kv-disk-space-mb "$((KV_GB * 1024))" \
  --kv-cache-min-tokens 4096 \
  --kv-cache-cold-max-tokens "$CTX" \
  --kv-cache-continued-interval-tokens "$CONTINUED" \
  --kv-cache-reject-different-quant
