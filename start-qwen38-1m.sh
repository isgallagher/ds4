#!/bin/bash
# Qwen3.8-Flash-Next — 1M profile: ONE resident session, YaRN 4.0, vision on.
#
#   Default: CTX=1048576  YARN=4.0  SESSIONS=1  KV_GB=240
#   Try something that fits better:  CTX=655360 YARN=2.5 ./start-qwen38-1m.sh   (plan ~108 GiB)
#                                    CTX=786432 YARN=3.0 ./start-qwen38-1m.sh   (plan ~114 GiB, borderline)
#   Try without images:              MMPROJ= ./start-qwen38-1m.sh
#   Re-warm the weights (gamble):    WARM=--warm-weights ./start-qwen38-1m.sh
#
# THE ROPE RECIPE IS THE VENDOR'S, NOT MINE
#   The model card prescribes exactly this for 1M: rope_type "yarn", factor 4.0,
#   original_max_position_embeddings 262144, rope_theta 10000000,
#   partial_rotary_factor 0.25, mrope_interleaved true, mrope_section [11,11,10].
#   ds4 implements static YaRN with the HF defaults (ds4.c:7086-7114, beta_fast 32,
#   beta_slow 1, mscale 0.1*ln(factor)+1 — the same attention_factor HF derives),
#   and the GGUF agrees with the card's rotary geometry:
#   qwen4exp.context_length = 262144, rope.dimension_count = 64 (= 0.25 x 256),
#   rope.freq_base = 10000000. Nothing in the engine caps ctx (no ceiling found in
#   ds4_server.c); the only related message is a warning when ctx > native AND the
#   factor is absent (ds4.c:60279). So the rope side is settled. Memory is not.
#
# MEMORY — THIS IS THE PART THAT MAY NOT FIT, ON THIS BOX, TODAY
#   Anchors measured here (Reference/m5-max-128gb-ds4-qwen38-flash-next-perf.md):
#     ctx 262,144 -> KV 8.33 GiB, workspace 11.68 GiB, model 69.73 GiB, plan 89.74, RSS 84.9
#     ctx 393,216 -> KV 12.50 GiB, workspace 13.68 GiB
#   Extrapolated to 1,048,576:
#     KV        33.32 GiB   (exact — KV is linear in rows, rows = ctx and ctx/4)
#     workspace 23.68 GiB   (two-point slope, 16 KiB/token — this one is inference)
#     model     69.73 GiB   (resident weights, Q4)
#     PLAN     ~126.7 GiB against a 116 GiB wired limit and 128 GiB of RAM.
#   Even if the workspace does NOT grow at all, the plan is 69.73 + 33.32 + 11.68 =
#   114.7 GiB, which leaves 1.3 GiB under the wired limit — no room for macOS, the
#   vision tower, or the store's pages. That is why this script does NOT pass
#   --warm-weights by default: without it the 69.73 GiB of weights are mapped but
#   not touched into the wired set at startup (ds4_server.c:15789, help text "Touch
#   resident weights at startup"), which is the only version with a real chance.
#   Whether macOS keeps them out under pressure is NOT measured here.
#
#   If it dies, the shape to look for is an allocation failure or a Metal residency
#   refusal at startup, not a slow turn. Then come down: 786,432 plans ~114 GiB,
#   655,360 plans ~108 GiB, 524,288 plans ~102 GiB (that one is start-qwen38-512k.sh).
#
# KV DISK TIER — TWO THINGS THAT WILL BITE AT 1M
#   1. The mid-prefill ladder. At the usual 32,768 interval one cold 1M rebuild
#      writes 32768 x (1+2+...+32) = 17.3M checkpoint tokens ≈ 567 GiB — more than
#      the whole 240 GiB budget and most of the free space on the volume. So the
#      default here is CONTINUED=0, which disables the ladder (ds4_kvstore.c:798).
#   2. The per-turn near-tail pool is min(budget/8, 16 GiB x sessions)
#      (ds4_kvstore.c:1026-1031). At SESSIONS=1 that ceiling is 16 GiB and KV_GB
#      cannot raise it — 16 GiB is a literal. One 1M checkpoint is ~35.8 GiB, so
#      per-turn resume checkpoints are impossible at this context: expect a
#      refusal line every turn and a full prefill after a restart. The cold path
#      still admits against the full budget, so a whole-prompt checkpoint can land
#      and a restart can still load it. Fixing the per-turn case needs a patch to
#      that literal, not a flag.
#
# Only ONE ds4-server runs on this machine. Never run this beside another profile.

set -euo pipefail
cd "$(dirname "$0")"

CTX="${CTX:-1048576}"
YARN="${YARN:-4.0}"
PORT="${PORT:-8080}"
SESSIONS="${SESSIONS:-1}"
KV_GB="${KV_GB:-240}"
KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache-1m}"
MODEL="${MODEL:-$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf}"
MMPROJ="${MMPROJ-$HOME/repos/ds4/gguf/mmproj-Qwen3.8-Flash-Next-Q8_0.gguf}"
MTP_FLAG="${MTP_FLAG:---mtp --mtp-timing}"
WARM="${WARM-}"
CONTINUED="${CONTINUED:-0}"

if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 <= 1.0) }'; then
  echo "refusing: ctx $CTX > native 262144 with YARN=$YARN — would silently degrade past 262k" >&2
  exit 1
fi
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 <= 262144 && y+0 > 1.0) }'; then
  echo "refusing: ctx $CTX is native but YARN=$YARN > 1 — that writes a foreign rotary frame into $KV_DIR" >&2
  exit 1
fi
if [ "$KV_DIR" = "$HOME/.ds4/kv-cache" ] || [ "$KV_DIR" = "$HOME/.ds4/kv-cache-512k" ]; then
  echo "refusing: KV_DIR=$KV_DIR belongs to another rope frame (factor $YARN writes its own)" >&2
  echo "          leave KV_DIR at its default, or point it at a dir no other profile writes" >&2
  exit 1
fi
[ -f "$MODEL" ] || { echo "refusing: model not found: $MODEL" >&2; exit 1; }
[ -z "$MMPROJ" ] || [ -f "$MMPROJ" ] || { echo "refusing: mmproj not found: $MMPROJ (use MMPROJ= for text only)" >&2; exit 1; }

WIRED=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
# Built as an array so a path with a space cannot split into two arguments.
VISION=()
[ -n "$MMPROJ" ] && VISION=(--vision "$MMPROJ")
KVGIB=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 8.33 * c / 262144.0 }')
WSGIB=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 11.68 + (16.0/1048576.0) * (c - 262144.0) }')
PLAN=$(awk -v kv="$KVGIB" -v ws="$WSGIB" 'BEGIN { printf "%.1f", 69.73 + kv + ws }')
WIREDBG=$(awk -v w="$WIRED" 'BEGIN { printf "%.0f", w / 1024.0 }')

echo "ds4 1m: ctx=$CTX yarn=$YARN sessions=$SESSIONS kv=${KV_GB}GiB dir=$KV_DIR port=$PORT"
echo "       model=$(basename "$MODEL") mmproj=$([ -n "$MMPROJ" ] && basename "$MMPROJ" || echo "text only")"
echo "       mtp='${MTP_FLAG}' warm='${WARM:-none}' continued=$CONTINUED (0 = ladder off)"
awk -v kv="$KVGIB" -v ws="$WSGIB" -v p="$PLAN" -v w="$WIREDBG" 'BEGIN {
  printf "       plan %.1f GiB = 69.73 model + %.2f KV + %.2f workspace (workspace extrapolated)\n", p, kv, ws
  printf "       wired limit %s GiB -> headroom %.1f GiB\n", w, w - p }'
if awk -v p="$PLAN" -v w="$WIREDBG" 'BEGIN { exit !(w > 0 && p + 4 > w) }'; then
  echo "       ! The plan meets or exceeds the wired limit. Expect this to fail at startup,"
  echo "         not merely to run slow: look for an allocation or Metal residency refusal."
  echo "       ! Fallbacks that plan clear of the limit: CTX=655360 YARN=2.5 (~108 GiB), or"
  echo "         start-qwen38-512k.sh (CTX=524288 YARN=2.0, ~102 GiB). CTX=786432 YARN=3.0 is"
  echo "         ~114 GiB and counts as a gamble, not a plan."
  echo "       ! Watch it live:  df -h /   and   ps -o rss= -p \$(pgrep -f ds4-server)"
fi
if [ "${WIRED:-0}" -eq 0 ]; then
  echo "       WARNING: iogpu.wired_limit_mb is unset (macOS default ~96 GiB):"
  echo "         sudo sysctl iogpu.wired_limit_mb=118784   # resets on reboot"
fi
mkdir -p "$KV_DIR"
echo
echo 'VERIFY AFTER START:'
echo '  1. the memory line reads KV ~33.32 GiB — that is the number that decides whether this fits'
echo '  2. no "context ... exceeds the native 262144 tokens" warning (means YaRN did not take)'
echo '  3. expect per-turn near-tail REFUSALS (16 GiB pool ceiling at SESSIONS=1 vs a ~35.8 GiB file)'
echo '  4. a cold rebuild is ~22 minutes at 800 t/s — do not interrupt it to test a restart'
echo
echo 'log it (server writes stderr, so tee alone captures nothing): ./start-qwen38-1m.sh >> ~/ds4-1m.log 2>&1'
echo 'watch memory:   ps -o rss= -p $(pgrep -f ds4-server) | awk '"'"'{printf "RSS %.1f GB\n", $1/1048576}'"'"''
echo 'watch routing:  grep -E "KV disk cache|context buffers|kv cache (hit|stored|evicted|refused)|exceeds the native"'
echo
echo 'sampling is the client'"'"'s job (the server takes temperature from each request).'
echo 'model card, thinking mode: temperature 1.0 top_p 0.95 top_k 20 min_p 0 presence_penalty 0 repetition_penalty 1'
echo 'model card, instruct mode: temperature 0.7 top_p 0.80 top_k 20 min_p 0 presence_penalty 1.5 repetition_penalty 1'
echo 'model card, inside 1M: reasoning output up to 262,144 tokens, final response up to 131,072'

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
