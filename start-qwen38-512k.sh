#!/bin/bash
# Qwen3.8-Flash-Next launcher — the shared implementation for all three profiles.
#
#   YOU RUN ONE OF THESE THREE, NOT THIS FILE DIRECTLY:
#     ./start-qwen38-512k.sh        512K, ONE resident session   (this file)
#     ./start-qwen38-512k-2s.sh     512K, TWO resident sessions
#     ./start-qwen38-1m.sh          1M,  ONE resident session, wired-limit gated
#
#   The two other scripts set a few variables and exec this one. That is deliberate:
#   the guards below are the ones that keep this box from silently running an
#   unscaled rope frame or an unwired store, and three copies of them drift apart.
#   Profile defaults this file sets: CTX=524288 YARN=2.0 SESSIONS=1 KV_GB=240
#   MTP_DRAFT=2 MTP_PREFILL=on WARM=--warm-weights CONTINUED=131072. Vision is on.
#
#   Overrides you may pass as environment, any of them:
#     CTX= YARN= SESSIONS= PORT= KV_GB= KV_DIR= MODEL= MMPROJ= WARM= CONTINUED=
#     MTP_DRAFT= MTP_TIMING= MTP_FLAG= MTP_PREFILL= WIRED_MIN_MB= PROFILE=
#   Examples:
#     MMPROJ= ./start-qwen38-512k.sh          text only, no vision tower
#     MTP_FLAG= ./start-qwen38-512k.sh        no speculation at all
#     WARM= ./start-qwen38-512k.sh            more headroom, slower first turn
#
# SPECULATION — what is on here, and what turning the knob further does
#   --mtp-draft N means "maximum autoregressive MTP draft tokens" and defaults to 1
#   (./ds4-server --help runtime; clamped to 16 at ds4.c:73830). With 1 the engine
#   stops after the first draft, and the server's batched verify stays off because
#   qwen4_batch_mtp requires draft > 1 (ds4_server.c:17415). So 2 is the setting that
#   turns the batched path on. Measured on this box: 43.78 t/s mean over 30 turns at
#   ctx 321-354k and 45.31 over 7 turns at 357-367k, against 38.6 at 250-257k on the
#   old single-draft path — roughly +13% to +17% while running deeper. (I first
#   published +22% from a 7-turn slice of one run; the full sample gives +13%.)
#   DO NOT BOTHER WITH --mtp-draft 3 ON THIS PATH. The batched loop never reads
#   mtp_draft_tokens again after the > 1 test: it commits 1 or 2 rows only
#   (ds4.c:83917, :83929) and stores exactly one pending draft per session (:84001).
#   Depth 3 exists on the NON-batched path only (ds4_server.c:15386 ->
#   ds4_session_qwen4_spec_cycle, ds4.c:77638), where qwen4_spec_depth() (:77604)
#   already picks 2 or 3 by itself and does not read the flag. Its own comment gives
#   the economics: the second draft accepts at ~0.6 on general prose, which does not
#   cover the wider cycle, and ~0.95+ on deterministic continuations for +10-20%.
#   There is no other speculator to stack on top of MTP. DSpark needs a separate
#   support GGUF that exists only for DeepSeek V4 Flash and V4.1, and "the two are
#   not stacked" (docs/SPECULATIVE_DECODING.md:37); split-KV self-speculation returns
#   false under __APPLE__ (ds4.c:18930). The "native BF16 n-grams" in the Qwen GGUF
#   are Engram embedding tables read from disk, not a drafter.
#   TWO SPECULATION PATHS, and only one of them prints per step:
#     --batched-session >= 1 -> qwen4_batch_mtp (ds4_server.c:15407). This is the
#       default. It prints NOTHING per step; its readout is the shutdown line
#       "Qwen3.8 mtp: N verify cycles, M first drafts accepted (%)" — first draft
#       only. Readings taken on this box: 87.0% over 13,962 cycles, 85.4% over
#       17,206, 82.1% over 50,803. Acceptance moves with the content.
#     SESSIONS=0 -> no --batched-session, batched_mode false, and DS4_MTP_TIMING=1
#       prints "ds4: mtp timing micro drafted= committed= ... total=..ms" per step.
#   Extra knobs with no rebuild: DS4_MTP_CONF_LOG, DS4_MTP_SPEC_LOG,
#   DS4_MTP_MIN_MARGIN (overrides --mtp-margin, default 3), DS4_MTP_STRICT,
#   DS4_MTP_BATCH_VERIFY, DS4_MTP_SPEC_DISABLE (kill switch). A batched verify
#   reorders floating-point reductions, so replies need not reproduce token for
#   token against the single-draft path.
#
#   MTP_PREFILL=on exports DS4_QWEN4_MTP_PREFILL=on. This makes prompt prefill
#   prepare the MTP predictor's own K/V and indexer history. The engine default is
#   "auto", which resolves to the ssd-streaming flag (ds4.c:1123) and is therefore
#   OFF on this resident-weights box, where prefill instead "initializes those cache
#   rows to zero" (docs/SPECULATIVE_DECODING.md:139). The docs say preparing it "can
#   improve draft acceptance for long generations"; the resolver's own comment warns
#   it "costs prefill time", and on resident weights no disk-read saving offsets
#   that. Nothing prints when it acts, so the only readout is the shutdown
#   acceptance line — compare it against 82.1% over 50,803 cycles, the last run
#   before it was turned on. Set MTP_PREFILL=off to go back to the engine default.
#
# WHY YaRN 2.0 AT 512K AND 4.0 AT 1M
#   The model card: "natively supports context lengths of up to 262,144 tokens ...
#   if the typical context length for your application is 524,288 tokens, it would be
#   better to set factor as 2.0." For 1M the card prescribes yarn factor 4.0 over
#   original_max_position_embeddings 262144. YaRN here is static (ds4.c:7086-7114,
#   beta_fast 32 / beta_slow 1, mscale 0.1*ln(f)+1), which is what every open-source
#   framework ships, and the card warns it costs some quality on short text. Native
#   context is 262,144, read out of the GGUF: qwen4exp.context_length = 262144.
#
# MEMORY — extrapolated from two measured points on THIS box, not from the card
#   Anchor A  ctx 262,144: KV 8.33, workspace 11.68, model 69.73 => plan 89.74,
#            RSS 84.9 measured.   Anchor B ctx 393,216: KV 12.50, workspace 13.68.
#   KV is linear in rows by construction (raw rows = ctx, compressed rows = ctx/4 + 1,
#   ds4.c:60277), so 8.33 GiB x ctx/262144 is exact. The 16 KiB/token workspace slope
#   is a two-point extrapolation — the server's own "context buffers" line is truth.
#   At 524,288: 16.66 + 15.68 + 69.73 = ~102 GiB planned. Wired limit here is
#   iogpu.wired_limit_mb=118784 (116 GiB); RAM 128 GiB.
#   THE PLAN IS PESSIMISTIC BY ABOUT 14 GiB ON THIS MODEL, and that is what makes two
#   slots possible: the 512k plan says ~119 GiB for 2 slots (over the 116 GiB limit),
#   yet a 2-slot run measured RSS 77.0 GiB on 2026-11-26. Read the plan as a warning,
#   not a verdict, and watch RSS: ps -o rss= -p $(pgrep -f ds4-server).
#
# KV DISK TIER — read this before you call a restart slow
#   1. Each profile owns a directory and a rope frame. Since patch 0020 the
#      checkpoint header carries a 24-bit provenance frame id (rope table, mscale,
#      native ctx, model, quant, ctx, model-file shape) and the server sweeps the
#      directory at startup, deleting anything that is not its own. Read the
#      "kv cache sweep" line: "removed=0 kept=N" means the profile is unchanged.
#   2. The per-turn near-tail pool is min(budget/8, 16 GiB x sessions)
#      (ds4_kvstore.c:1130, and the 2 x sessions file cap at :1184). At KV_GB=240
#      budget/8 is 30 GiB, so ONE slot gets 16 GiB and TWO slots get 30 GiB, not 32.
#      It is a TOKEN ceiling: a checkpoint costs 113.6 MiB + ~33.3 KiB per token, so
#      16 GiB holds about 500,000 tokens. Measured here 2026-11-27: a frontier at
#      355,882 tokens stored as 11,699 MiB and the next one evicted it
#      ("evicted reason=near-tail-bound"), because two at that size are 22.8 GiB.
#      Above ~350k tokens one slot keeps a single frontier; past ~500k it refuses
#      new ones and every restart becomes a full rebuild.
#   3. The mid-prefill ladder is expensive at this size: at the usual 32,768 interval
#      a single cold rebuild writes ~4.46M checkpoint tokens = ~145 GiB. The default
#      here is 131,072 (four rungs, ~43 GiB). 0 disables it (ds4_kvstore.c:798).
#
# Only ONE ds4-server runs on this machine. Never start a profile alongside another.

set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-512k}"
CTX="${CTX:-524288}"
YARN="${YARN:-2.0}"
PORT="${PORT:-8080}"
SESSIONS="${SESSIONS:-1}"
KV_GB="${KV_GB:-240}"
MODEL="${MODEL:-$HOME/repos/ds4/gguf/Qwen3.8-Flash-Next-Q4.gguf}"
MMPROJ="${MMPROJ-$HOME/repos/ds4/gguf/mmproj-Qwen3.8-Flash-Next-Q8_0.gguf}"
MTP_DRAFT="${MTP_DRAFT:-2}"
# Off by default: the per-step lines exist only on the non-batched path (see header),
# so with SESSIONS >= 1 this env buys silence and adds clock reads to that path only.
MTP_TIMING="${MTP_TIMING:-0}"
MTP_PREFILL="${MTP_PREFILL:-on}"
# Built as an array so the words cannot split on a path or a value with a space.
if [ -n "${MTP_FLAG:-}" ]; then
  MTPARGS=($MTP_FLAG)                       # caller-supplied, deliberately word-split
else
  MTPARGS=(--mtp --mtp-timing --mtp-draft "$MTP_DRAFT")
fi
WARM="${WARM---warm-weights}"
CONTINUED="${CONTINUED:-131072}"
# 0 = warn only. The 1M profile raises this to a hard gate.
WIRED_MIN_MB="${WIRED_MIN_MB:-0}"
# The store directory follows the rope factor, so a factor change never reuses
# another profile's checkpoints. Patch 0020 makes that a correctness matter only at
# the sweep; keeping the directories apart is what keeps each store WARM.
case "$(awk -v y="$YARN" 'BEGIN { printf "%.1f", y+0 }')" in
  1.0|0.*) KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache}" ;;
  2.0)     KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache-512k}" ;;
  4.0)     KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache-1m}" ;;
  *)       KV_DIR="${KV_DIR:-$HOME/.ds4/kv-cache-yarn$(awk -v y="$YARN" 'BEGIN { printf "%g", y }')}" ;;
esac

# ---- guards ---------------------------------------------------------------------
# Above native you must carry a real factor, or you silently degrade past 262k.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 > 262144 && y+0 <= 1.0) }'; then
  echo "refusing: ctx $CTX > native 262144 with YARN=$YARN — would silently degrade past 262k" >&2
  exit 1
fi
# A native run must not carry a factor, or its checkpoints are indistinguishable.
if awk -v c="$CTX" -v y="$YARN" 'BEGIN { exit !(c+0 <= 262144 && y+0 > 1.0) }'; then
  echo "refusing: ctx $CTX is native but YARN=$YARN > 1 — that writes a foreign rotary frame into $KV_DIR" >&2
  exit 1
fi
# Never let two rope frames share one directory.
for other in "$HOME/.ds4/kv-cache" "$HOME/.ds4/kv-cache-512k" "$HOME/.ds4/kv-cache-1m"; do
  if [ "$KV_DIR" = "$other" ]; then
    case "$other" in
      *kv-cache-512k) want="2.0" ;;
      *kv-cache-1m)   want="4.0" ;;
      *)              want="1.0 (native)" ;;
    esac
    if [ "$want" != "$YARN" ] && ! awk -v y="$YARN" -v w="$want" 'BEGIN { exit !(y+0 == w+0) }'; then
      echo "refusing: KV_DIR=$KV_DIR belongs to the factor-$want frame; this run is factor $YARN" >&2
      echo "          leave KV_DIR at its default, or point it at a directory no other profile writes" >&2
      exit 1
    fi
  fi
done
[ -f "$MODEL" ] || { echo "refusing: model not found: $MODEL" >&2; exit 1; }
[ -z "$MMPROJ" ] || [ -f "$MMPROJ" ] || { echo "refusing: mmproj not found: $MMPROJ (use MMPROJ= for text only)" >&2; exit 1; }

# ---- environment the engine needs ----------------------------------------------
# The factor must reach the engine through the environment, or the engine keeps the
# native rotary frame and only WARNS ("context ... exceeds the native 262144 tokens",
# ds4.c:60279) and carries on. That export was missing when this script was first
# written on 2026-11-26: the warning fired and the profile ran 524288 with native
# rope. The backstop at the bottom of this file makes that impossible to repeat.
if awk -v y="$YARN" 'BEGIN { exit !(y+0 > 1.0) }'; then export DS4_QWEN4_YARN_FACTOR="$YARN"; fi
if [ "$MTP_TIMING" != "0" ]; then export DS4_MTP_TIMING=1; fi
if [ "$MTP_PREFILL" = "on" ] || [ "$MTP_PREFILL" = "1" ]; then
  export DS4_QWEN4_MTP_PREFILL=on
elif [ "$MTP_PREFILL" = "off" ] || [ "$MTP_PREFILL" = "0" ]; then
  export DS4_QWEN4_MTP_PREFILL=off
else
  echo "refusing: MTP_PREFILL=$MTP_PREFILL — use on, off, or auto" >&2
  exit 1
fi

# ---- memory and the wired limit -------------------------------------------------
WIRED=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
WIREDBG=$(awk -v w="$WIRED" 'BEGIN { printf "%.0f", w / 1024.0 }')
KVGIB=$(awk -v c="$CTX" -v n="$SESSIONS" 'BEGIN { printf "%.2f", 8.33 * c / 262144.0 * n }')
KVSLOT=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 8.33 * c / 262144.0 }')
WSGIB=$(awk -v c="$CTX" 'BEGIN { printf "%.2f", 11.68 + (16.0/1048576.0) * (c - 262144.0) }')
PLAN=$(awk -v kv="$KVGIB" -v ws="$WSGIB" 'BEGIN { printf "%.1f", 69.73 + kv + ws }')
POOL=$(awk -v g="$KV_GB" -v n="$SESSIONS" 'BEGIN { b = g / 8.0; s = 16.0 * n; printf "%.0f", (b < s ? b : s) }')

if [ "${WIRED_MIN_MB:-0}" -gt 0 ] && [ "${WIRED:-0}" -lt "$WIRED_MIN_MB" ]; then
  NEEDGIB=$(awk -v m="$WIRED_MIN_MB" 'BEGIN { printf "%.0f", m / 1024.0 }')
  echo "refusing: profile $PROFILE needs the GPU wired limit at ${NEEDGIB} GiB or higher." >&2
  echo "          iogpu.wired_limit_mb is ${WIRED} MiB (${WIREDBG} GiB). This box has 128 GiB of RAM." >&2
  echo "          Raise it, then run this again. It does NOT survive a reboot:" >&2
  echo "            sudo sysctl iogpu.wired_limit_mb=${WIRED_MIN_MB}" >&2
  echo "          Check it took:  sysctl -n iogpu.wired_limit_mb" >&2
  exit 1
fi

# ---- argv -----------------------------------------------------------------------
VISION=()
[ -n "$MMPROJ" ] && VISION=(--vision "$MMPROJ")
# SESSIONS=0 omits --batched-session entirely, which sets batched_mode false
# (ds4_server.c:17356) and moves speculation onto the engine path that prints.
BATCH=()
[ "$SESSIONS" -gt 0 ] && BATCH=(--batched-session "$SESSIONS")
WARMARGS=()
[ -n "$WARM" ] && WARMARGS=("$WARM")

echo "ds4 $PROFILE: ctx=$CTX yarn=$YARN sessions=$SESSIONS kv=${KV_GB}GiB dir=$KV_DIR port=$PORT"
echo "         model=$(basename "$MODEL") mmproj=$([ -n "$MMPROJ" ] && basename "$MMPROJ" || echo "text only")"
echo "         mtp='${MTPARGS[*]}' mtp_prefill=$MTP_PREFILL warm='${WARM:-none}' continued=$CONTINUED"
if [ "$SESSIONS" -gt 0 ]; then
  echo "         speculation path: qwen4_batch_mtp (batched verify) — per-step lines NOT printed"
else
  echo "         speculation path: engine multi-draft — DS4_MTP_TIMING=1 prints per-step lines"
fi
awk -v kv="$KVGIB" -v kvs="$KVSLOT" -v n="$SESSIONS" -v ws="$WSGIB" -v p="$PLAN" -v w="$WIREDBG" -v pool="$POOL" -v g="$KV_GB" 'BEGIN {
  printf "         plan %.1f GiB = 69.73 model + %.2f KV (%.2f per slot x %s) + %.2f workspace\n", p, kv, kvs, n, ws
  printf "         wired limit %s GiB -> headroom %.1f GiB   (plans run ~14 GiB pessimistic here)\n", w, w - p
  printf "         per-turn resume pool %.0f GiB = min(%s/8, 16 x %s); a frontier costs ~33 KiB/token\n", pool, g, n }'
if awk -v p="$PLAN" -v w="$WIREDBG" 'BEGIN { exit !(w > 0 && p + 4 > w) }'; then
  echo "         ! The plan meets or exceeds the wired limit. Measured RSS on this model runs"
  echo "         ! ~14 GiB under plan, so this may still work — watch it: ps -o rss= -p \$(pgrep -f ds4-server)"
fi
if [ "${WIRED:-0}" -eq 0 ]; then
  echo "         WARNING: iogpu.wired_limit_mb is unset (macOS default ~96 GiB). Raise it (resets on reboot):"
  echo "           sudo sysctl iogpu.wired_limit_mb=118784"
fi
mkdir -p "$KV_DIR"
if ls "$KV_DIR"/*.kv >/dev/null 2>&1; then
  echo "         NOTE: $KV_DIR already holds checkpoints. Since patch 0020 the server sweeps them"
  echo "         at startup and deletes any file whose version, payload ABI or provenance frame"
  echo "         (rope table, model, quant, ctx, model-file shape) is not its own, so a foreign-"
  echo "         frame file can no longer be loaded. Read the 'kv cache sweep' line."
  echo "         To delete nothing this run: --kv-cache-reject-different-quant=off (report only)."
fi
echo
echo 'VERIFY AFTER START:'
echo '  1. the memory line reads KV per slot and the plan clears the wired limit'
echo '  2. no "context ... exceeds the native 262144 tokens" warning (that means YaRN did not take)'
echo '  3. sweep line: "removed=0 kept=N" on a restart of the same profile. Anything removed means'
echo '     the directory or the profile changed — read the reason= on each per-file line.'
echo '  4. first turn after a restart: a "kv cache hit text" line then a SHORT prefill (measured'
echo '     ctx=353953..355882:1929 prompt done 4.631s, and tokens=159959 load=538.1 ms).'
echo '  5. rate: quote 50-57 t/s only for the FIRST MINUTE after an idle gap or a restart. The'
echo '     same server sustains 30-36 t/s through a long turn. Both are true — 2026-11-27 killed'
echo '     the game-tenant, power-cap, thermal and depth explanations with measurements; what is'
echo '     left is the GPU clock, which swings 715-1453 MHz on this workload and cannot be locked'
echo '     on macOS. Use tools/decode-probe.py for any before/after comparison.'
echo '  6. speculation on the batched path prints NOTHING per step. Its readout is the shutdown'
echo '     line "Qwen3.8 mtp: N verify cycles, M first drafts accepted (%)" — first draft only.'
echo '     For per-step drafted=/committed= ms lines you need SESSIONS=0 MTP_TIMING=1.'
echo
echo "log it (server writes stderr, so tee alone captures nothing): ./start-qwen38-${PROFILE}.sh >> ~/ds4-${PROFILE}.log 2>&1"
echo 'watch memory:   ps -o rss= -p $(pgrep -f ds4-server) | awk '"'"'{printf "RSS %.1f GB\n", $1/1048576}'"'"''
echo 'watch routing:  grep -E "KV disk cache|kv cache sweep|context buffers|kv cache (hit|stored|evicted|refused)|exceeds the native"'
echo 'watch mtp:      grep -E "Qwen3.8 mtp|mtp timing|mtp conf|mtp spec miss" ~/ds4-'"$PROFILE"'.log | tail -20'
echo 'measure decode: ./tools/decode-probe.py --reps 3 --max-tokens 512 --gap 20'
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
  ${MTPARGS[@]+"${MTPARGS[@]}"} \
  ${WARMARGS[@]+"${WARMARGS[@]}"} \
  --prefill-chunk 8192 \
  --tool-memory-max-ids 32768 \
  --kv-disk-dir "$KV_DIR" \
  --kv-disk-space-mb "$((KV_GB * 1024))" \
  --kv-cache-min-tokens 4096 \
  --kv-cache-cold-max-tokens "$CTX" \
  --kv-cache-continued-interval-tokens "$CONTINUED" \
  --kv-cache-reject-different-quant
