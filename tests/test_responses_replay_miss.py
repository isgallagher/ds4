#!/usr/bin/env python3
"""Live-server regression test: Responses text-turn live-KV cache miss (Bug 2).

WHAT IT REPRODUCES
  The victim (a real pi session, qwen3.8-flash-next-393k, ctx 393216) re-prefills
  ~112K tokens on the FIRST TEXT turn after a run of tool-call turns:
      live kv cache miss RESPPROTO live=304375 prompt=304396 common=298741 reason=token-mismatch
  Tool turns HIDE the drift (they continue from live via the call_id fast path,
  responses_prepare_live_continuation -> REUSE_RESPONSES_TOOL_OUTPUT, and never run
  the full token compare). A text turn has no tool tail, so it falls to
  REUSE_RESPONSES_VISIBLE / REUSE_MEMORY_TOKEN; the client's re-render no longer
  matches the live KV mid-history, so common < live -> miss + big re-prefill.

WHY IT DRIVES REAL PI (not raw HTTP)
  ds4 routes a request to a slot BY REUSE (job_slot_score -> slot_probe_reuse,
  ds4_server.c:14864/11602). The victim's miss landed on the slot that already
  held the full live prefix, because pi is a stable client that keeps reusing one
  session/slot. A raw-HTTP client that fails to reuse would instead evict to a
  fresh slot (old_pos=0 -> reason=no-live-checkpoint), which is a DIFFERENT path
  and would not reproduce the mid-history token-mismatch. Driving pi reproduces the
  real client's slot behaviour, so the miss fires as it does in the victim.

THE SHAPE (two pi runs in one scratch session)
  run 1 (fresh session):  a tool task that ends in a plain-text answer.
  run 2 (--continue):     a one-line follow-up. Its REQUEST is
                          [history incl. the text answer] + a new user message,
                          i.e. input tail = assistant text, NO trailing
                          function_call_output. That request is the miss turn
                          (the exact victim shape).
  The final prefill block in the server log is that text-turn request.

VERDICT (read from the server log, no model token is ever printed)
  GREEN (fix holds): the text-turn block has no `live kv cache miss ...
    reason=token-mismatch`, and continues from live (cached ~= live, small suffix).
  RED (bug present): the text-turn block logs `live kv cache miss ... reason=
    token-mismatch` with common < live (the mid-history gap).

Run the server with DS4_CACHE_MISS_DEBUG=1 so a miss also dumps the divergent
token window (base64; decoded here only, truncated, and never the full marker).

Exit codes: 0 GREEN, 2 RED, 3 indeterminate (text turn not found / reason other),
  1 setup/infra error.

Usage:
  python3 tests/test_responses_replay_miss.py \
      --log ~/.ds4/ds4-server.log --pi /path/to/pi \
      --model qwen3.8-flash-next-393k
"""
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

MISS_RE = re.compile(
    r"live kv cache miss(?: RESPPROTO)? live=(\d+) prompt=(\d+) common=(\d+) .*reason=(\S+)")
# Generic prefill line:  ds4-server: <chat|completion> ctx=<c>..<p>:<s> [FLAGS] prompt start
# The FLAGS field (log_flags) is present for Responses/tool turns, e.g.
# "RESPPROTO TOOLS"; it is empty for a bare request. Both must be tolerated or
# the text-turn block (always a Responses request, so always has the flags) is
# never matched.
PREFILL_RE = re.compile(
    r"ds4-server: (?:chat|completion) ctx=(\d+)\.\.(\d+):(\d+)(?: .*)?prompt start")
# Responses fast-path hit line (informational: which tier served it).
CONT_RE = re.compile(
    r"responses live continuation RESPPROTO match=(\S+) ids=(\d+) cached=(\d+) prompt=(\d+)")
# Disk fallback (informational: how much it re-prefilled).
DISK_RE = re.compile(r"disk_cached_tokens: (\d+)|disk load.*?tokens=(\d+)")
# Probe window (DS4_CACHE_MISS_DEBUG=1).
PROBE_ROW_RE = re.compile(
    r"CACHEMISS_DEBUG pos=(\d+) live=(\d+) prompt=(\d+) match=(==|!=) live64=(\S+) prompt64=(\S+)")

# run 1: several tool calls, then a plain-text answer (no tool).
TOOL_TASK = (
    "Using the bash tool: run `echo a`, then `echo b`, then `echo c`, each in "
    "its own tool call. Once all three have run, stop calling tools and answer, "
    "in a single word, what is 2 plus 2."
)
# run 2 (follow-up): forces a text turn whose request tail is the prior answer.
FOLLOWUP = "In one word, repeat the exact word you just answered with."


def run_pi(pi: str, model: str, thinking: str, session_dir: Path,
           continue_prev: bool, task: str, timeout: int) -> None:
    scratch = session_dir.parent
    scratch.mkdir(parents=True, exist_ok=True)
    session_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PI_OFFLINE"] = "1"
    cmd = [
        pi, "--print", "--mode", "json",
        "--provider", "localhost", "--model", model,
        "--thinking", thinking,
        "--session-dir", str(session_dir),
        "--no-extensions", "--no-skills",
        "--no-context-files", "--no-prompt-templates",
    ]
    if continue_prev:
        cmd.append("--continue")
    cmd += ["--", task]
    sys.stderr.write("+ " + " ".join(cmd) + "\n")
    subprocess.run(cmd, cwd=str(scratch), env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=timeout, check=False)


def blocks(lines):
    """Split the log tail into per-request blocks keyed on the prefill line.
    Block i spans from just after prefill line i-1 up to and including prefill
    line i. The last block is the final (text-turn) request."""
    pre = [i for i, ln in enumerate(lines) if PREFILL_RE.search(ln)]
    out = []
    for k, i in enumerate(pre):
        start = pre[k - 1] + 1 if k > 0 else 0
        out.append(lines[start: i + 1])
    return out


def classify(block_lines):
    miss = cont = prefill = None
    disk = None
    for ln in block_lines:
        m = MISS_RE.search(ln)
        if m:
            miss = (int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4))
        c = CONT_RE.search(ln)
        if c:
            cont = {"match": c.group(1), "ids": int(c.group(2)),
                    "cached": int(c.group(3)), "prompt": int(c.group(4))}
        p = PREFILL_RE.search(ln)
        if p:
            prefill = (int(p.group(1)), int(p.group(2)), int(p.group(3)))
        d = DISK_RE.search(ln)
        if d:
            disk = int(next(g for g in d.groups() if g))
    return {"miss": miss, "cont": cont, "prefill": prefill, "disk": disk}


def verdict(blk):
    miss, pre = blk["miss"], blk["prefill"]
    if miss is not None:
        live, prompt, common, reason = miss
        gap = live - common
        if reason == "token-mismatch" and common < live:
            return 2, [f"MISS live={live} prompt={prompt} common={common} reason={reason}",
                       f"  mid-history gap live-common={gap}"]
        return 3, [f"miss present but reason={reason} (expected token-mismatch)"]
    if pre is not None:
        cached, prompt, suffix = pre
        tier = blk["cont"]["match"] if blk["cont"] else "n/a"
        if suffix <= 4096:
            return 0, [f"no live miss; continues from live (tier={tier}, "
                       f"cached={cached} prompt={prompt} suffix={suffix})"]
        return 3, [f"no miss but suffix not small (tier={tier}, cached={cached} "
                   f"prompt={prompt} suffix={suffix})"]
    return 3, ["no prefill line in the text-turn block"]


def dump_probe(lines):
    import base64
    rows = [ln for ln in lines if PROBE_ROW_RE.search(ln)]
    if not rows:
        return
    bad = [ln for ln in rows if "match=!=" in ln]
    print(f"\n--- DS4_CACHE_MISS_DEBUG window: {len(rows)} rows, {len(bad)} mismatches ---")
    for ln in rows[:48]:
        m = PROBE_ROW_RE.search(ln)
        pos, lv, pv, match = m.group(1), m.group(2), m.group(3), m.group(4)
        try:
            lt = base64.b64decode(m.group(5)).decode("utf-8", "replace")
            pt = base64.b64decode(m.group(6)).decode("utf-8", "replace")
        except Exception:
            lt = pt = "?"
        print(f"{'!!' if match != '==' else '  '} pos={pos} live={lv} prompt={pv} {match}")
        if match != "==":
            print(f"     live  : {lt[:160]!r}")
            print(f"     prompt: {pt[:160]!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", required=True, help="server log path (tail is read)")
    ap.add_argument("--pi", required=True, help="path to the pi binary")
    ap.add_argument("--model", default="qwen3.8-flash-next-393k")
    ap.add_argument("--thinking", default="low",
                    help="must stay ON: the miss is a reasoning re-render drift")
    ap.add_argument("--timeout", type=int, default=240, help="per-pi-run timeout (s)")
    args = ap.parse_args()

    logp = Path(os.path.expanduser(args.log))
    if not logp.exists():
        print(f"ERROR: server log not found: {logp}", file=sys.stderr); sys.exit(1)
    if not os.path.isfile(args.pi):
        print(f"ERROR: pi binary not found: {args.pi}", file=sys.stderr); sys.exit(1)

    off = logp.stat().st_size
    # Fresh scratch per invocation: a stale session in a reused dir makes run 1
    # CONTINUE the previous invocation's conversation, contaminating the shape.
    import tempfile
    root = Path(tempfile.mkdtemp(prefix="pi-mmtest-", dir="/tmp/fc-debug"))
    sdir = root / "sessions"
    for i, (task, cont) in enumerate([(TOOL_TASK, False), (FOLLOWUP, True)]):
        sys.stderr.write(f"--- pi run {i + 1} (continue={cont}) ---\n")
        t0 = time.time()
        try:
            run_pi(args.pi, args.model, args.thinking, sdir, cont, task, args.timeout)
        except subprocess.TimeoutExpired:
            print("ERROR: pi run timed out", file=sys.stderr); sys.exit(1)
        sys.stderr.write(f"  done in {time.time() - t0:.1f}s\n")

    with open(logp, "r", errors="replace") as f:
        f.seek(off)
        tail = f.read().splitlines()
    if not tail:
        print("ERROR: no new server log lines (server not up or wrong --log)",
              file=sys.stderr); sys.exit(1)

    blks = blocks(tail)
    if not blks:
        print("ERROR: no prefill block found in the tail (did the requests run?)",
              file=sys.stderr); sys.exit(3)

    # Show every request's decision for context, then verdict on the last (text) turn.
    print("\n=== per-request decisions (first -> last) ===")
    for i, b in enumerate(blks):
        c = classify(b)
        p = c["prefill"]
        tag = f"pre ctx={p[0]}..{p[1]}:{p[2]}" if p else "no prefill"
        if c["miss"]:
            tag += f"  MISS live={c['miss'][0]} common={c['miss'][2]} {c['miss'][3]}"
        elif c["cont"]:
            tag += f"  HIT {c['cont']['match']}"
        print(f"  req{i}: {tag}")

    last = classify(blks[-1])
    code, lines = verdict(last)
    print("\n=== text-turn verdict (last request) ===")
    for l in lines:
        print(l)
    if last["miss"]:
        dump_probe(blks[-1])
    print(f"\nVERDICT: {'RED (miss reproduced)' if code == 2 else 'GREEN (no miss)' if code == 0 else 'INDETERMINATE'}")
    sys.exit(code)


if __name__ == "__main__":
    main()
