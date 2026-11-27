#!/usr/bin/env python3
"""decode-probe.py — measure ds4-server decode throughput under one fixed shape.

Why this exists: the server log shows decode swinging between ~20 and ~58 t/s with
no factor that the log can explain (not another client, not context depth, not turn
length, not the checkpoint writes). Every tuning question — --mtp-draft, --mtp-margin,
the batched versus engine speculation path — needs the SAME workload run the SAME way
before and after a change, or the answer is noise. This is that workload.

It is deliberately boring: one prompt, temperature 0, no tools, no streaming, N
requested tokens, K repetitions with a gap between them. The server does the counting
(prompt_tokens and completion_tokens come back in the response), so depth is measured
rather than guessed.

Usage:
  ./tools/decode-probe.py                          # 3 reps x 512 tokens, shallow
  ./tools/decode-probe.py --depth 100000 --reps 2  # pad the prompt to ~100k tokens
  ./tools/decode-probe.py --max-tokens 2000 --gap 300
  ./tools/decode-probe.py --url http://127.0.0.1:8080 --model <name-from-/v1/models>

Notes:
  * Each rep costs a real prefill. --depth 100000 costs roughly 100-350 s of prefill
    per rep on this box, so raise depth deliberately, not by accident.
  * Run the SAME command before and after a restart. Compare the block, not a rep.
  * Leave --gap generous (300 s) if you suspect a sustained-load effect: the slow
    windows in the live log lasted minutes and recovered after ~2 minutes of idle.
"""
import argparse
import json
import statistics
import sys
import time
import urllib.request

FILLER = ("The following numbered lines exist only to occupy context in this probe. "
          "Line {i}: the quick brown fox journal keeps the calibration steady.\n")


def build_prompt(depth: int, marker: str) -> str:
    head = (f"Decode probe {marker}. Reply with a short numbered list counting upward "
            "from 1 and stop when told. Do not use tools.\n")
    if depth <= 0:
        return head
    out, i, chars = [head], 1, len(head)
    target = int(depth * 3.6)          # ~3.6 chars/token for this filler; the server's
    while chars < target:              # own prompt_tokens is the number that counts
        line = FILLER.format(i=i)
        out.append(line)
        chars += len(line)
        i += 1
    return "".join(out)


def one(url: str, model: str, prompt: str, max_tokens: int, timeout: int):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }).encode()
    req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    wall = time.monotonic() - t0
    u = data.get("usage", {}) or {}
    completion = u.get("completion_tokens") or 0
    return wall, u.get("prompt_tokens") or 0, completion


def main() -> int:
    ap = argparse.ArgumentParser(description="fixed-shape decode probe")
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    ap.add_argument("--model", default="", help="empty = ask /v1/models for the first id")
    ap.add_argument("--depth", type=int, default=0, help="pad the prompt to ~N tokens")
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--gap", type=float, default=20.0, help="seconds between reps")
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--marker", default=time.strftime("%H%M%S"))
    args = ap.parse_args()

    model = args.model
    if not model:
        with urllib.request.urlopen(args.url.rstrip("/") + "/v1/models", timeout=30) as r:
            model = r.read().decode()
        model = json.loads(model)["data"][0]["id"]

    prompt = build_prompt(args.depth, args.marker)
    print(f"probe {args.marker}: model={model} depth~{args.depth} "
          f"max_tokens={args.max_tokens} reps={args.reps} gap={args.gap}s")

    rates = []
    for n in range(1, args.reps + 1):
        wall, ptok, ctok = one(args.url, model, prompt, args.max_tokens, args.timeout)
        rate = ctok / wall if wall > 0 and ctok else 0.0
        rates.append(rate)
        print(f"  rep {n}: prompt={ptok} completion={ctok} wall={wall:.2f}s "
              f"decode={rate:.1f} t/s")
        if n < args.reps:
            time.sleep(args.gap)

    if len(rates) > 1:
        print(f"  mean={statistics.fmean(rates):.1f} t/s  stdev="
              f"{statistics.pstdev(rates):.1f}  min={min(rates):.1f}  max={max(rates):.1f}")
    print("  compare this whole block against the same command on another build.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
