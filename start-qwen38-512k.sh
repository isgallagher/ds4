#!/bin/bash
# Qwen3.8-Flash-Next — 512K profile: ONE resident session, YaRN 2.0, vision on.
#
#   Default: CTX=524288  YARN=2.0  SESSIONS=1  KV_GB=240  MTP_DRAFT=2  MTP_TIMING=0
#   You do NOT need to pass SESSIONS. The default 1 already sends
#   --batched-session 1, which is the configuration measured at 46.96 t/s on
#   2026-11-27. A bare ./start-qwen38-512k.sh is the same command.
#   Try without images:  MMPROJ= ./start-qwen38-512k.sh
#   Try without speculation: MTP_FLAG= ./start-qwen38-512k.sh
#   Try the old single-draft speculation: MTP_DRAFT=1 ./start-qwen38-512k.sh
#   Measure a clean decode rate (no per-step timing work): MTP_TIMING=0 ./start-qwen38-512k.sh
#   Try without weight warming (more headroom, slower first turn): WARM= ./start-qwen38-512k.sh
#
# SPECULATION — why this script now passes --mtp-draft (added 2026-11-26)
#   The engine flag --mtp-draft N (see ./ds4-server --help runtime) DEFAULTS TO 1,
#   and with 1 the engine stops after the first draft (ds4.c:88782) and the server's
#   batched verify path stays off, because qwen4_batch_mtp requires draft > 1
#   (ds4_server.c:17415). Measured first-draft acceptance on this box is 85.7%
#   (68,520 verify cycles, 58,705 accepted), so the second draft is worth trying.
#   MTP_DRAFT=2 turns on both; set it back to 1 to reproduce the old behaviour.
#   TWO SPECULATION PATHS, and only one of them prints (measured 2026-11-27 00:0x):
#     --batched-session >= 1  ->  s.batched_mode is true, so the server takes the
#       qwen4_batch_mtp branch (ds4_server.c:15407) and verifies through
#       server_eval_tokens. THIS IS THE DEFAULT HERE, and it prints nothing per step.
#     --batched-session 0     ->  batched_mode false, so the engine's own multi-draft
#       function runs (ds4_server.c:15386 -> ds4_session_eval_speculative_argmax_impl,
#       ds4.c:88531), and THAT is where DS4_MTP_TIMING prints its per-step lines.
#   Measured on this box with MTP_DRAFT=2 on the batched path: 46.96 t/s mean over 7
#   turns at ctx 322-327k, against 38.6 t/s at 250-257k before the change — at least
#   +22% while DEEPER, so the gain is understated.
#   So MTP_TIMING defaults OFF: with batching on it buys nothing and prints nothing.
#   Turn it on for the A/B run with SESSIONS=0 MTP_TIMING=1, and read
#     "ds4: mtp timing micro drafted=N committed=M draft=..ms snapshot=..ms
#      verify=..ms total=..ms"   (also decode2/margin-skip variants).
#   At 47 t/s the budget per token is 21.3 ms, so compare total= against that.
#   SESSIONS=0 is now accepted by this script and means "do not pass --batched-session".
#   Extra knobs, no rebuild needed:
#   DS4_MTP_CONF_LOG (per-step margin), DS4_MTP_SPEC_LOG (first-draft misses),
#   DS4_MTP_MIN_MARGIN (overrides --mtp-margin, default 3), DS4_MTP_SPEC_DISABLE
#   (kill switch). NOTE: --mtp-timing, the FLAG, only prints its cumulative
#   acceptance line when the session is freed, which with one slot means at server
#   shutdown — that line is the readout on the default path. A batched verify also
#   reorders floating-point reductions, so replies need not reproduce token for token
#   with the old single-draft path.
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
#   1. This profile writes its OWN rope frame (factor 2.0). Since patch 0020 the
#      checkpoint header carries a 24-bit provenance frame id (rope table, mscale,
#      native ctx, model, quant, ctx, model-file shape) and the server sweeps the
#      directory at startup, deleting anything that is not its own — so a foreign-
#      frame file can no longer be loaded even by accident. Read the
#      "kv cache sweep" line. The guard below still refuses the native dir outright,
#      because keeping profiles apart also keeps their stores warm.
#   2. The per-turn near-tail pool is min(budget/8, 16 GiB x sessions)
#      (ds4_kvstore.c:1130). At SESSIONS=1 the ceiling is 16 GiB and KV_GB CANNOT
#      raise it — the 16 GiB is a literal in the code. It is a TOKEN ceiling, not a
#      context-length block: a checkpoint costs 113.6 MiB + ~33.3 KiB per token, so
#      16 GiB holds about 500,000 tokens. MEASURED HERE 2026-11-27: a frontier at
#      355,882 tokens stored fine as 11,699 MiB, and the next frontier evicted it
#      ("evicted reason=near-tail-bound") because two of them at this size are
#      22.8 GiB > 16 GiB. So above ~350k tokens the pool keeps ONE frontier, and
#      past ~500k it refuses new ones. One client is fine; a second conversation
#      then evicts the first on every turn. The cold and shutdown paths use the
#      whole budget, so a restart can still load a full-prompt checkpoint (measured:
#      shutdown store 11,636 MiB at 353,953 tokens, then a 1,637.9 ms load).
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
MTP_DRAFT="${MTP_DRAFT:-2}"
# Off by default: the per-step lines only exist on the non-batched speculative path
# (see the header), so with SESSIONS>=1 this env buys silence.
MTP_TIMING="${MTP_TIMING:-0}"
MTP_FLAG="${MTP_FLAG:---mtp --mtp-timing --mtp-draft $MTP_DRAFT}"
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

# The factor must reach the engine through the environment, or the engine keeps the
# native rotary frame and only WARNS: "context ... exceeds the native 262144 tokens"
# (ds4.c:60279) and carries on. This export was missing when the script was first
# written on 2026-11-26, the warning fired, and the profile ran 524288 with native
# rope. The backstop below is what makes that impossible to repeat quietly.
if awk -v y="$YARN" 'BEGIN { exit !(y+0 > 1.0) }'; then export DS4_QWEN4_YARN_FACTOR="$YARN"; fi

# Per-step speculation timing (see the header). It adds clock reads to the speculative
# path, so the decode rate read with it on is not the clean rate.
if [ "$MTP_TIMING" != "0" ]; then export DS4_MTP_TIMING=1; fi

WIRED=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
# Built as an array so a path with a space cannot split into two arguments.
VISION=()
[ -n "$MMPROJ" ] && VISION=(--vision "$MMPROJ")
# SESSIONS=0 means "do not pass --batched-session at all", which is what turns
# s.batched_mode false (ds4_server.c:17356) and moves speculation onto the engine's
# own multi-draft path — the one that prints the DS4_MTP_TIMING lines. Slot count
# stays 1 either way.
BATCH=()
[ "$SESSIONS" -gt 0 ] && BATCH=(--batched-session "$SESSIONS")
PLAN=$(awk -v c="$CTX" 'BEGIN { kv = 8.33 * c / 262144.0; ws = 11.68 + (16.0/1048576.0) * (c - 262144.0); printf "%.1f", 69.73 + kv + ws }')
KVGIB=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 8.33 * c / 262144.0 }')
WSGIB=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 11.68 + (16.0/1048576.0) * (c - 262144.0) }')
WIREDBG=$(awk -v w="$WIRED" 'BEGIN { printf "%.0f", w / 1024.0 }')

echo "ds4 512k: ctx=$CTX yarn=$YARN sessions=$SESSIONS$([ "$SESSIONS" -gt 0 ] || echo " (no --batched-session: engine speculative path)") kv=${KV_GB}GiB dir=$KV_DIR port=$PORT"
echo "         model=$(basename "$MODEL") mmproj=$([ -n "$MMPROJ" ] && basename "$MMPROJ" || echo "text only")"
echo "         mtp='${MTP_FLAG}' warm='${WARM:-none}' continued=$CONTINUED"
if [ "$SESSIONS" -gt 0 ]; then
  echo "         speculation path: qwen4_batch_mtp (batched verify) — per-step lines NOT printed"
else
  echo "         speculation path: engine multi-draft — DS4_MTP_TIMING=1 prints per-step lines"
fi
if [ "$MTP_TIMING" != "0" ]; then
  echo "         DS4_MTP_TIMING=1 — per-step 'ds4: mtp timing micro drafted= committed=' lines"
  echo "         (adds clock reads to the speculative path: use MTP_TIMING=0 for a clean rate)"
fi
awk -v kv="$KVGIB" -v ws="$WSGIB" -v p="$PLAN" -v w="$WIREDBG" 'BEGIN {
  printf "         plan %.1f GiB = 69.73 model + %.2f KV + %.2f workspace (extrapolated)\n", p, kv, ws
  printf "         wired limit %s GiB -> headroom %.1f GiB\n", w, w - p }'
if [ "${WIRED:-0}" -eq 0 ]; then
  echo "         WARNING: iogpu.wired_limit_mb is unset (macOS default ~96 GiB). Raise it (resets on reboot):"
  echo "           sudo sysctl iogpu.wired_limit_mb=118784"
fi
mkdir -p "$KV_DIR"
if ls "$KV_DIR"/*.kv >/dev/null 2>&1; then
  echo "         NOTE: $KV_DIR already holds checkpoints. Since patch 0020 the server sweeps"
  echo "         them at startup and deletes any file whose version, payload ABI or provenance"
  echo "         frame (rope table, model, quant, ctx, model-file shape) is not its own, so a"
  echo "         foreign-frame file can no longer be loaded. Read the 'kv cache sweep' line."
  echo "         To delete nothing this run: --kv-cache-reject-different-quant=off (report only)."
fi
echo
echo 'VERIFY AFTER START:'
echo '  1. the memory line reads KV ~16.66 GiB and the plan lands near 102 GiB, not above the wired limit'
echo '  2. no "context ... exceeds the native 262144 tokens" warning (that means YaRN did not take)'
echo '  3. first turn after a restart: a "kv cache hit text" line then a SHORT prefill (measured'
echo '     ctx=353953..355882:1929 prompt done 4.631s). Decode with --mtp-draft 2 measured 44-56 t/s'
echo '     at 320-360k depth; the 20s-30s band was the old single-draft number at shallower depth.'
echo '  4. sweep line: "removed=0 kept=N" on a restart of this same profile (frame ff8819 here).'
echo '     Anything removed means the dir or the profile changed — read the reason= on each line.'
echo '  5. speculation on this path (batched verify) prints NOTHING per step. Its readout is the'
echo '     acceptance line at shutdown: "Qwen3.8 mtp: N verify cycles, M first drafts accepted'
echo '     (%)" — measured 87.0% over 13,962 cycles with MTP_DRAFT=2. For per-step drafted=/committed='
echo '     ms lines you need the OTHER path: SESSIONS=0 MTP_TIMING=1 (no --batched-session).'
echo '     MTP_DRAFT=1 is the old single-draft behaviour.'
echo
echo 'log it (server writes stderr, so tee alone captures nothing): ./start-qwen38-512k.sh >> ~/ds4-512k.log 2>&1'
echo 'watch memory:   ps -o rss= -p $(pgrep -f ds4-server) | awk '"'"'{printf "RSS %.1f GB\n", $1/1048576}'"'"''
echo 'watch routing:  grep -E "KV disk cache|kv cache sweep|context buffers|kv cache (hit|stored|evicted|refused)|exceeds the native"'
echo 'watch mtp:      grep -E "Qwen3.8 mtp|mtp timing|mtp conf|mtp spec miss" ~/ds4-512k.log | tail -20'
echo
echo 'sampling is the client'"'"'s job (the server takes temperature from each request).'
echo 'model card, thinking mode: temperature 1.0 top_p 0.95 top_k 20 min_p 0 presence_penalty 0 repetition_penalty 1'
echo 'model card, instruct mode: temperature 0.7 top_p 0.80 top_k 20 min_p 0 presence_penalty 1.5 repetition_penalty 1'

# Backstop: never start a YaRN-sized context without the factor in the environment.
if awk -v c="$CTX" 'BEGIN { exit !(c+0 > 262144) }' && [ -z "${DS4_QWEN4_YARN_FACTOR:-}" ]; then
  echo "refusing: DS4_QWEN4_YARN_FACTOR is unset — ctx $CTX would run past the native 262144" >&2
  echo "          with no rotary scaling, which is a silent quality loss, not an error" >&2
  exit 1
fi

exec ./ds4-server \
  --ctx "$CTX" \
  ${BATCH[@]+"${BATCH[@]}"} \
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
