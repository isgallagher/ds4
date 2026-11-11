#!/usr/bin/env python3
"""Regression test: image tool-result turns must not fork the live KV.

Bug shape (the "reprocesses the entire prompt" bug with embedded images):
a tool result that carries an inline image (e.g. `read` of a .png) is
appended to the live KV through the Responses tool-output continuation
path.  That path copies the image's vision block out of the full
re-render's token stream.  The copy used to omit the block's
vision_start/vision_end tokens, so the live KV carried a truncated block
while every full re-render of the same history carries the complete
block.  The next request that runs the full token compare (a plain user
turn, an interrupted turn, a compaction) then forks at the first image
block and re-prefills the whole prompt.

Flow (mirrors a pi session, including echoing response items back as
reasoning/message/function_call items the way pi does):
  R1  user asks the model to read an image file -> the model emits a
      function_call.  Full render; the KV is correct at this point.
  R2  the tool result arrives (tool-output continuation) carrying the
      image inline.  The continuation path appends the image's vision
      block to the KV.  In the broken build this is where the fork is
      born; the tool-output tier does not run the token compare, so the
      turn itself looks fine.
  R3  a plain user turn.  No trailing tool output -> the full token
      compare runs.  RED: `live kv cache miss ... reason=token-mismatch`
      with common < live (full re-prefill).  GREEN: no miss line; the
      turn continues in lockstep.

Contract:
  exit 0  GREEN: no `live kv cache miss` line was logged for R2/R3 and
          R3 completed.
  exit 2  RED:   a token-mismatch miss with common < live appeared in
          the R2/R3 window (the pre-fix signature).
  exit 3  invalid: server error, or R1 produced no function_call (the
          repro does not hold; rerun).

Usage:
  python3 tests/test_responses_image_read_repro.py \
      --port 8080 --log /tmp/fc-debug/server-probe2.log

The server must be running with the vision model loaded (the probe /
capture server is the intended target).  The log file must be the one
the server is currently writing; the test scans only lines appended
while R2/R3 run, so a miss from some other client in that window would
be a false RED (use a dedicated server, or check the request count in
the miss line's window if a RED appears unexpectedly).
"""

import argparse
import json
import sys
import urllib.request

# 1x1 white PNG.
PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
    "AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)
DATA_URI = "data:image/png;base64," + PNG_B64

REPLAY_TYPES = {"reasoning", "message", "function_call"}


def post(base, payload, timeout=900):
    req = urllib.request.Request(
        base + "/v1/responses",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def base_payload(args, items, **extra):
    p = {
        "model": args.model,
        "input": items,
        "stream": False,
        "prompt_cache_key": args.prompt_cache_key,
        "store": False,
    }
    p.update(extra)
    return p


def echo_items(resp):
    """The response items pi would put back into the next request."""
    return [it for it in resp.get("output", [])
            if it.get("type") in REPLAY_TYPES]


def find_call(items):
    for it in items:
        if it.get("type") == "function_call":
            return it
    return None


def log_line_count(path):
    with open(path, "rb") as f:
        return sum(1 for _ in f)


def log_lines_since(path, start):
    with open(path, "r", errors="replace") as f:
        for _ in range(max(0, start)):
            f.readline()
        return f.read()


def user_msg(text):
    return {"type": "message", "role": "user", "status": "completed",
            "content": [{"type": "input_text", "text": text}]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--log", required=True,
                    help="server log being written right now (probe lines)")
    ap.add_argument("--model", default="qwen3.8-flash-next")
    ap.add_argument("--prompt-cache-key", default="test-image-read-repro")
    args = ap.parse_args()

    base = f"http://{args.host}:{args.port}"
    tools = [
        {"type": "function", "name": "read",
         "description": "Read a file from disk.",
         "parameters": {"type": "object",
                        "properties": {"path": {"type": "string"}},
                        "required": ["path"]}},
    ]

    ask = ("Use the read tool to read the file /tmp/probe-card.png right "
           "now. Do not answer anything else.")

    # ---- R1: model emits the read call
    resp1 = post(base, base_payload(args, [user_msg(ask)], tools=tools))
    if resp1.get("status") != "completed":
        print(f"INVALID: R1 did not complete: {resp1.get('status')}",
              file=sys.stderr)
        sys.exit(3)
    out1 = echo_items(resp1)
    call1 = find_call(out1)
    if call1 is None:
        print("INVALID: R1 produced no function_call; rerun the test.",
              file=sys.stderr)
        sys.exit(3)

    start = log_line_count(args.log)

    # ---- R2: the tool result carries the image inline (tool-output tier)
    tool_out = {"type": "function_call_output", "call_id": call1["call_id"],
                "output": [
                    {"type": "input_text",
                     "text": "Read image file [image/png]"},
                    {"type": "input_image", "image_url": DATA_URI},
                ]}
    r2_input = [user_msg(ask)] + out1 + [tool_out]
    resp2 = post(base, base_payload(args, r2_input, tools=tools))
    if resp2.get("status") != "completed":
        print(f"INVALID: R2 did not complete: {resp2.get('status')}",
              file=sys.stderr)
        sys.exit(3)
    out2 = echo_items(resp2)

    # ---- R3: a plain user turn forces the full token compare
    r3_input = r2_input + out2
    call2 = find_call(out2)
    if call2 is not None:
        # close the extra tool turn with a plain text result
        r3_input.append(
            {"type": "function_call_output", "call_id": call2["call_id"],
             "output": "ok"})
    r3_input.append(user_msg("Describe the image in one short line."))
    resp3 = post(base, base_payload(args, r3_input, tools=tools))
    if resp3.get("status") != "completed":
        print(f"INVALID: R3 did not complete: {resp3.get('status')}",
              file=sys.stderr)
        sys.exit(3)

    window = log_lines_since(args.log, start)
    miss_lines = [l for l in window.splitlines()
                 if "live kv cache miss" in l]
    red = [l for l in miss_lines if "reason=token-mismatch" in l]
    if red:
        print("RED: full re-prefill after the image tool result")
        for l in miss_lines:
            print("  " + l.strip())
        sys.exit(2)
    print("GREEN: image tool result + plain user turn stayed in lockstep "
          "(no live kv cache miss in the R2/R3 window)")
    sys.exit(0)


if __name__ == "__main__":
    main()
