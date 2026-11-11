#!/bin/bash
# Qwen3.8-Flash-Next — DEFAULT profile: native 262k context, vision enabled.
# Quality lane: no YaRN, native context length. Use this unless you specifically need a longer window.
#
# Provenance: flags were inherited from upstream issue threads + sibling scripts (owner, 2 Oct 2026).
# Two KV flags were previously set twice with disagreeing values and have been deduped to the LAST
# value, which is what the running server was started with:
#   --kv-cache-cold-max-tokens            60000 (removed) -> 150000 (kept)
#   --kv-cache-continued-interval-tokens   5000 (removed) -> 32768 (kept)
# NOTE: "last wins" is assumed, not verified in the parser. If it turns out to be first-wins, this
# file changes behaviour relative to the old script — swap the values back.
#
# Verified facts (2 Oct 2026):
#   --ctx 262144 = the model's native context (docs/QWEN38_FLASH_NEXT.md); no YaRN needed at/below it.
#   --tokens is -n: MAX TOKENS TO GENERATE (ds4_server.c:15654), clamped to min(tokens, ctx) (:15083).
#     The old value 131072 was ONE THIRD of the engine's own default (.default_tokens = 393216,
#     ds4_server.c:15575) and equals only the card's response cap. Dropped so 393216 applies;
#     at this ctx it clamps to 262144 anyway, so nothing is over-asked.
#   NOTE: max thinking is NOT unlocked by --tokens, and ds4-server has NO --think* flags at all
#     (they exist only for ds4 / ds4-agent). Thinking mode is chosen PER REQUEST by the model name
#     the client sends: qwen3.8-flash-next-reasoner / -chat / base alias (ds4_server.c:1190, 1206).
#     So to change thinking from pi, change PI_MODEL's alias - not a server flag.
#     Separately, ds4.c:60097 downgrades DS4_THINK_MAX to DS4_THINK_HIGH whenever ctx < 393216
#     (gate applies to qwen4exp; tested at ds4_server.c:18196). At 262k you get `high`, silently.
#     Use start-qwen38-longctx.sh when you actually want max.
#   If a full-context run ever fails to allocate: sudo sysctl iogpu.wired_limit_mb=118784
#     (macOS caps GPU-wired at ~75% of RAM by default; resets on reboot).
#   --vision mmproj is 588 MB — negligible against ~86 GB RSS; keep it, it is not a memory lever.
#   Measured RSS on this host (M5 Max, 110 GB) at 262k with vision: ~86 GB.

set -euo pipefail
cd "$(dirname "$0")"

exec ./ds4-server \
  --ctx 262144 \
  --port 8080 --host 0.0.0.0 --cors \
  -m "$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf" \
  --mtp \
  --vision "$HOME/repos/ds4/gguf/mmproj-Qwen3.8-Flash-Next-Q8_0.gguf" \
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
