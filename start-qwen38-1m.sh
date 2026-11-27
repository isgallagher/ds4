#!/bin/bash
# Qwen3.8-Flash-Next — 1M profile, ONE resident session, vision on, MTP on.
#
# A thin entry point: it sets the 1M defaults, the hard wired-limit gate, and hands
# off to start-qwen38-512k.sh for every guard and the engine environment.
#
#   Default: CTX=1048576 YARN=4.0 SESSIONS=1 KV_GB=240 MTP_DRAFT=2 MTP_PREFILL=on
#            WARM= (weights NOT touched into the wired set) CONTINUED=0 (ladder off)
#   Smaller contexts that fit better:
#     CTX=786432  YARN=3.0 ./start-qwen38-1m.sh    plan ~114 GiB — a gamble
#     CTX=655360  YARN=2.5 ./start-qwen38-1m.sh    plan ~108 GiB
#   Try without images:   MMPROJ= ./start-qwen38-1m.sh
#   Gamble on warm weights: WARM=--warm-weights ./start-qwen38-1m.sh
#   Lower the gate deliberately: WIRED_MIN_MB=0 ./start-qwen38-1m.sh
#
# THE WIRED-LIMIT GATE — why this profile refuses instead of warning
#   This profile needs iogpu.wired_limit_mb >= 118784 (116 GiB) and REFUSES to start
#   below it, because at 1M the failure mode of a low limit is a Metal residency or
#   allocation refusal partway through a long prefill, not a clean error at launch.
#   The limit does not survive a reboot, so the check runs on every start. To raise it:
#     sudo sysctl iogpu.wired_limit_mb=118784
#     sysctl -n iogpu.wired_limit_mb          # check it took
#   The macOS default on a 128 GiB box is about 96 GiB. Do not push this near 128 GiB:
#   the wired set is memory the compressor and the file cache cannot reclaim, and the
#   system needs its own share.
#
# THE ROPE RECIPE IS THE VENDOR'S, NOT OURS
#   The model card prescribes exactly this for 1M: rope_type "yarn", factor 4.0,
#   original_max_position_embeddings 262144, rope_theta 10000000,
#   partial_rotary_factor 0.25, mrope_interleaved true, mrope_section [11,11,10].
#   ds4 implements static YaRN with the HF defaults (ds4.c:7086-7114, beta_fast 32,
#   beta_slow 1, mscale 0.1*ln(factor)+1) and the GGUF agrees with the card's rotary
#   geometry: qwen4exp.context_length = 262144, rope.dimension_count = 64
#   (= 0.25 x 256), rope.freq_base = 10000000. Nothing in the engine caps ctx; the
#   only related message is a warning when ctx exceeds native AND the factor is
#   absent (ds4.c:60279), which the launcher's backstop makes impossible. So the rope
#   side is settled. Memory is the part that may not fit.
#
# MEMORY — the arithmetic, and how much of it is measured
#   Measured anchors on this box (Reference/m5-max-128gb-ds4-qwen38-flash-next-perf):
#     ctx 262,144 -> KV 8.33 GiB, workspace 11.68 GiB, model 69.73 GiB, plan 89.74,
#                    RSS 84.9 GiB
#     ctx 393,216 -> KV 12.50 GiB, workspace 13.68 GiB
#   Extrapolated to 1,048,576:
#     KV        33.32 GiB   EXACT — KV is linear in rows (raw = ctx, compressed = ctx/4+1)
#     workspace 23.68 GiB   INFERENCE — a two-point slope of 16 KiB/token
#     model     69.73 GiB   measured, resident Q4 weights
#     PLAN     ~126.7 GiB against a 116 GiB wired limit and 128 GiB of RAM.
#   The plan runs about 14 GiB pessimistic on this model (512k: 102.07 planned against
#   88.5 GiB RSS measured), which puts a mature 1M single slot near 113 GiB — a few GiB
#   of margin, one anchor, inference. Even if the workspace did not grow at all the
#   plan is 114.7 GiB, which leaves 1.3 GiB: no room for macOS, the vision tower, or
#   the store's pages. That is why WARM is off by default here — without --warm-weights
#   the 69.73 GiB of weights are mapped but not touched into the wired set at startup
#   ("Touch resident weights at startup"), which is the only version with a real chance.
#   Whether macOS keeps them out under pressure is NOT measured.
#   If it dies, the shape to look for is an allocation or Metal residency refusal, not
#   a slow turn. Then come down: 786,432 plans ~114 GiB, 655,360 ~108 GiB, and
#   start-qwen38-512k.sh is the 524,288 profile that fits comfortably.
#
# 1M IS A READ-ONCE SHAPE, NOT AN AGENT SHAPE — the part with nothing to do with RAM
#   The per-turn near-tail pool is min(budget/8, 16 GiB x sessions), and 16 GiB is a
#   literal in the code (ds4_kvstore.c:1130) that KV_GB cannot raise. A checkpoint
#   costs 113.6 MiB + ~33.3 KiB per token, so 16 GiB stops holding a frontier at about
#   500,000 tokens. A 1M frontier is ~35.8 GiB. So above ~500k tokens this profile
#   stores NO per-turn frontier at any KV_GB with one session, and every restart is a
#   full rebuild of the whole prompt: ~15 minutes at 1,140 t/s, ~25 minutes at the
#   683 t/s average measured on large rebuilds. Fixing it needs a patch to that
#   literal, not a flag.
#   The mid-prefill ladder is off for the same reason: at the usual 32,768 interval one
#   cold 1M rebuild writes 32,768 x (1+2+...+32) = 17.3M checkpoint tokens = ~567 GiB,
#   more than the whole 240 GiB budget. CONTINUED=0 disables it (ds4_kvstore.c:798).
#
# Only ONE ds4-server runs on this machine. Never start it alongside another profile.

set -euo pipefail
cd "$(dirname "$0")"

export PROFILE="${PROFILE:-1m}"
export CTX="${CTX:-1048576}"
export YARN="${YARN:-4.0}"
export SESSIONS="${SESSIONS:-1}"
# Mapped, not wired. See the MEMORY section: this is what gives the profile a chance.
export WARM="${WARM-}"
# Ladder off. See the read-once section: at 32,768 a 1M rebuild writes ~567 GiB.
export CONTINUED="${CONTINUED:-0}"
# Hard gate. 116 GiB, the value this box already carries; below it, refuse and print
# the command rather than fail inside a long prefill.
export WIRED_MIN_MB="${WIRED_MIN_MB:-118784}"

echo "1M profile: expect per-turn checkpoint refusals above ~500k tokens, and a full"
echo "rebuild (~15-25 min) after any restart. Read the header before you interrupt one."
echo "model card, inside 1M: reasoning output up to 262,144 tokens, final response up to 131,072."
echo

exec ./start-qwen38-512k.sh "$@"
