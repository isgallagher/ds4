#!/bin/bash
# Qwen3.8-Flash-Next — LONG-CONTEXT profile: YaRN-extended, text-only (no vision encoder).
#
#   Default: CTX=393216, YARN=1.5   <-- the MINIMUM that unlocks max thinking
#   Bigger:  CTX=524288  YARN=2  ./start-qwen38-longctx.sh
#   Largest: CTX=1048576 YARN=4  ./start-qwen38-longctx.sh   (1M — may not fit; see arithmetic)
#
# WHY 1.5 AND NOT 2
#   ds4.c:6993 parses the factor with atof() and enables YaRN whenever factor > 1.0, so FRACTIONAL
#   factors are valid. 262144 x 1.5 = 393216 = exactly DS4_THINK_MAX_MIN_CONTEXT (ds4.c:427).
#   YaRN costs short-prompt quality — ds4.c:6986-6988 says so outright — so use the smallest factor
#   that clears the job. Same reasoning as the 1.34x / 350K entry in ~/llama-model.ini.
#
# PREREQUISITE — CHECK THIS FIRST
#   `sysctl iogpu.wired_limit_mb` reads 0 (unset) on this machine => macOS default ~75% of RAM,
#   about 82 GB. The 262k server already sits at ~86 GB RSS, so anything past native context very
#   likely needs the bump (the same conclusion ~/llama-model.ini reached for llama.cpp):
#     sudo sysctl iogpu.wired_limit_mb=118784      # ~116 GB to the GPU; RESETS ON REBOOT
#
# WHY YaRN IS MANDATORY ABOVE NATIVE
#   Native context is 262144 (docs/QWEN38_FLASH_NEXT.md). ds4.c:57907 only WARNS when ctx > native
#   and YaRN is absent — it does not clamp — and the warning is guarded by `static bool warned_ctx`,
#   so it prints once per process on stderr. A "512k" server with no YaRN runs happily and quietly
#   degrades past 262k. Verify by grepping the startup log for "exceeds the native".
#
# THIS IS THE ONLY PROFILE THAT CAN ASK FOR MAX THINKING
#   ds4.c:60097 downgrades DS4_THINK_MAX -> DS4_THINK_HIGH whenever ctx < 393216, silently, for every
#   family except DEEPSEEK41 (tested: ds4_server.c:18196). 393216 is the card's own budget:
#   reasoning max 262144 + response max 131072.
#   Note also: ds4-server accepts NO --think* flags (those are ds4 / ds4-agent only). Thinking mode
#   is chosen per request by the model name the client sends — qwen3.8-flash-next-reasoner enables
#   thinking; -chat / -no-think / -nothink disable it (ds4_server.c:1187-1212); the BASE alias
#   qwen3.8-flash-next is in neither list and falls through to the engine default. To change thinking
#   from pi, change the alias in pi's config, not this script.
#
# MEMORY ARITHMETIC (M5 Max, 110 GB) — an estimate from ONE measured point, not a spec
#   Q4 resident weights 69.74 GiB = ~74.9 GB (docs). Measured RSS at 262k with vision ~86 GB, so
#   context + scratch ~10.6 GB at 262k. Linear: +393216 ~+5 GB; 512k ~21 GB (~96 GB total);
#   1M ~41 GB (~116 GB, over budget). Counter-consideration: gated delta-net keeps constant-size
#   recurrent state, the block-sparse indexer scales as ctx/4 (ds4.c:57905), and the 95.37 GiB
#   n-gram table stays on disk — so per-token RAM may be far below a transformer's. For calibration,
#   ~/llama-model.ini's own measurement (UD-Q2_K_XL, fp16 KV): 8.6 GB KV at 350K, ~93.5 GB wired
#   total. Start it and watch RSS; the command is printed below.
#
# Only ONE of these servers can run at a time on this machine — do not start both.

set -euo pipefail
cd "$(dirname "$0")"

CTX="${CTX:-393216}"
YARN="${YARN:-1.5}"
PORT="${PORT:-8080}"
MTP_FLAG="${MTP_FLAG:---mtp}"   # MTP_FLAG=--mtp-timing on the first run: prints acceptance counters
MTP_FLAG="--mtp --mtp-timing"

# Guard: above native you must have a real factor, or you silently degrade past 262k.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 <= 1.0) }'; then
  echo "refusing: ctx $CTX > native 262144 with YARN=$YARN — would silently degrade past 262k" >&2
  exit 1
fi

export DS4_QWEN4_YARN_FACTOR="$YARN"
echo "ds4 long-context: ctx=$CTX  YaRN=$YARN  port=$PORT  (vision disabled)"

if awk -v c="$CTX" 'BEGIN { exit !(c+0 < 393216) }'; then
  echo "note: ctx $CTX is below 393216 — max thinking will be silently served as 'high'"
fi

echo 'watch memory in another terminal:  ps -o rss= -p $(pgrep -f ds4-server) | awk '"'"'{printf "RSS %.1f GB\n", $1/1048576}'"'"''

exec ./ds4-server \
  --ctx "$CTX" \
  --port "$PORT" --host 0.0.0.0 --cors \
  -m "$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf" \
  $MTP_FLAG \
  --warm-weights \
  --prefill-chunk 8192 \
  --tool-memory-max-ids 32768 \
  --kv-disk-dir ~/.ds4/kv-cache \
  --kv-disk-space-mb 122880 \
  --kv-cache-min-tokens 4096 \
  --kv-cache-cold-max-tokens 393216 \
  --kv-cache-continued-interval-tokens 32768 \
  --kv-cache-reject-different-quant 
#  --kv-cache-boundary-trim-tokens 0 \
#  --kv-cache-boundary-align-tokens 4096
