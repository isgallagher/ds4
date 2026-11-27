#!/bin/bash
# Qwen3.8-Flash-Next — SINGLE-CLIENT profile: 1 resident sessions, YaRN-extended, text-only.
#
#   Default: CTX=393216  YARN=1.5  KV_GB=240
#   Speculation off: MTP_FLAG= ./start-qwen38-longctx.sh
#
# Only ONE ds4-server can run on this machine

set -euo pipefail
cd "$(dirname "$0")"

CTX="${CTX:-393216}"
YARN="${YARN:-1.5}"
PORT="${PORT:-8080}"
KV_GB="${KV_GB:-240}"
KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache}"
MTP_FLAG="${MTP_FLAG:---mtp --mtp-timing}"   # --mtp-timing prints acceptance counters

# Guard: above native you must have a real factor, or you silently degrade past 262k.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 <= 1.0) }'; then
  echo "refusing: ctx $CTX > native 262144 with YARN=$YARN — would silently degrade past 262k" >&2
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
  echo "         1 slot at ctx $CTX may not fit. Raise it (resets on reboot):"
  echo "           sudo sysctl iogpu.wired_limit_mb=118784"
fi

export DS4_QWEN4_YARN_FACTOR="$YARN"
echo "ds4: ctx=$CTX YaRN=$YARN kv=${KV_GB}GiB dir=$KV_DIR port=$PORT (vision disabled)"
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

exec ./ds4-server \
  --ctx "$CTX" \
  --port "$PORT" --host 0.0.0.0 --cors \
  -m "$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf" \
  ${MTP_FLAG:+$MTP_FLAG} \
  --vision "$HOME/repos/ds4/gguf/mmproj-Qwen3.8-Flash-Next-Q8_0.gguf" \
  --warm-weights \
  --prefill-chunk 8192 \
  --tool-memory-max-ids 32768 \
  --kv-disk-dir "$KV_DIR" \
  --kv-disk-space-mb "$((KV_GB * 1024))" \
  --kv-cache-min-tokens 4096 \
  --kv-cache-cold-max-tokens "$CTX" \
  --kv-cache-continued-interval-tokens 32768 \
  --kv-cache-reject-different-quant
