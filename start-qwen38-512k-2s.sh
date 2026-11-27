#!/bin/bash
# Qwen3.8-Flash-Next — 512K profile, TWO resident sessions, vision on, MTP on.
#
# This is a thin entry point. It sets the two-slot defaults and hands off to
# start-qwen38-512k.sh, which holds every guard, the memory arithmetic, and the
# engine environment. Nothing here duplicates that, so the profiles cannot drift.
#
#   Default: CTX=524288 YARN=2.0 SESSIONS=2 KV_GB=240 MTP_DRAFT=2 MTP_PREFILL=on
#   The one-slot version:  ./start-qwen38-512k.sh
#   The 1M version:        ./start-qwen38-1m.sh
#
# WHY TWO SLOTS FIT EVEN THOUGH THE PLAN SAYS THEY DO NOT
#   Two slots at 524,288 plan 2 x 16.66 GiB of KV + 15.68 GiB workspace + 69.73 GiB
#   model = ~119 GiB, against a 116 GiB wired limit (iogpu.wired_limit_mb=118784).
#   The plan is pessimistic by roughly 14 GiB on this model: a 2-slot 512k run
#   measured RSS 77.0 GiB on 2026-11-26, and the 11 Nov 2-slot capture at
#   ctx 393,216 ran 18 h 51 min at RSS 81.6 GiB. So it fits while both conversations
#   are not full. Watch it:  ps -o rss= -p $(pgrep -f ds4-server)
#
# WHAT THE SECOND SLOT BUYS
#   The per-turn resume pool rises from min(KV_GB/8, 16 x 1) to min(KV_GB/8, 16 x 2).
#   At the default KV_GB=240 that is 30 GiB, not 32 — budget/8 is the binding term.
#   Set KV_GB=256 to reach the 32 GiB cap. The file count cap is 2 x sessions
#   (ds4_kvstore.c:1184). Both conversations keep their own frontier instead of one
#   evicting the other every turn, which is what happens above ~350k tokens on one slot.
#
# WHAT THE SECOND SLOT COSTS — this is the reason it is not the default
#   Prompt work always wins over decode on this server. A peer's prefill halts your
#   generation for its whole length, measured as a ~10x decode loss (40.4 -> 4.2 t/s)
#   while the peer prefills, and the worst sustained case in the 11 Nov capture was
#   7,654 tokens in 2,195 s = 3.5 t/s. A long prefill at 512k is minutes of silence.
#   Two conversations above ~350k tokens each also exceed the pool together and go
#   back to evicting each other. If you want two conversations to feel like one,
#   this is the right script; if you want one conversation to be as fast as possible,
#   use start-qwen38-512k.sh.

set -euo pipefail
cd "$(dirname "$0")"

export PROFILE="${PROFILE:-512k-2s}"
export SESSIONS="${SESSIONS:-2}"

exec ./start-qwen38-512k.sh "$@"
