# Bug 2 test plan — Responses text-turn live-KV cache miss

The miss is the **first text turn after a run of tool-call turns**, in a session
that has been long enough for mid-history drift to accumulate. This doc is the
executable plan; the driver is `tests/test_responses_replay_miss.py`.

## Mechanism (source-verified, `ds4_server.c`)

| turn shape | request input tail | probe tier (`slot_probe_reuse_locked` :11602) | token compare? |
|---|---|---|---|
| tool turn | `function_call_output` | `REUSE_RESPONSES_TOOL_OUTPUT` (call_id match, :11657) | **no** — drift masked |
| text turn | assistant message + new user | `REUSE_RESPONSES_VISIBLE` / `REUSE_MEMORY_TOKEN` (:11634, :11690) | **yes, full prefix** — `common == live_pos` required (:11691) |

The client re-renders every prior turn (reasoning items, message items,
`function_call`, `function_call_output`) on each request. If any re-rendered
token differs from the raw sampled bytes held in the live KV, `common < live`
and the text turn logs:

```
live kv cache miss RESPPROTO live=<L> prompt=<P> common=<C> vision=... reason=token-mismatch
```

(`generate_job_inner` :13589; `reason=token-mismatch` = `common != old_pos`,
`trace_cache_miss_reason` :11844). The victim: `live=304375 prompt=304396
common=298741` — prompt grew +21, common ended **5,634 tokens before** the live
end: the divergence is **mid-history**, in the era the tool fast path had been
masking.

**Leading hypothesis (post-disk-load desync — matches the owner's "re-render
might be wrong" point, and the calibration run).** A fresh session never
misses: the client's re-render of every prior turn stays bit-exact with the
live KV, so the text turn hits (verified, both thinking levels). The victim
differed in exactly one structural way, and it is where `common` lands: the
session's live state was **rebuilt from a disk-snapshot load** (line 562,
cr=192512), and `common=298741` is precisely the token frontier at the **end
of that disk-load turn**. Before that boundary the client's re-render and the
live KV agree; the divergence is in what the live KV holds **after** the
load — the model's **raw sampled bytes** (think blocks, DSML tool-call text)
that a later text turn re-renders *from the client's stored items*, and where
the re-render no longer matches the sampled bytes. The tool turns between the
load and the text turn never exposed it (fast path, no token compare).

**Not yet confirmed — the probe settles it.** `DS4_CACHE_MISS_DEBUG=1`
(commit `c13f616`) dumps the ±32-token window as base64 on every miss; the `!=`
rows name the exact divergent field. Candidates, in the order the victim
structure predicts: (1) a re-rendered **think/reasoning block** for a
post-load turn (raw sampled bytes vs. the stored summary); (2) a re-rendered
**DSML tool call** (raw bytes vs. re-serialized `function_call`); (3) a mutable
field (id/timestamp). All three candidates sit *after* the 192512 prefix, so
the window should start just past the load boundary.

## Test contract

| | signal (server log, text-turn block) | exit |
|---|---|---|
| **RED** (bug) | `live kv cache miss ... reason=token-mismatch`, `common < live`, mid-history gap (`live - common` >> new-turn delta) | 2 |
| **GREEN** (fix holds) | no miss line; text turn continues from live — `ctx=c..p:s` with small `s` (new-turn delta), no ~100K re-prefill | 0 |

The fix under test (intake §3): canonicalize the Responses checkpoint on text
turns (reuse `canonicalize_tool_checkpoint` / `ds4_session_rewrite_from_common`
:12975/:13031). GREEN must hold for **two consecutive** text turns after tool
turns, not just one (the rewrite must persist for the following request too).

## Calibration (first live run, 2026-10-06, qwen3.8-flash-next-393k @ 393k)

The minimal two-run shape is **GREEN** (no text-turn miss) at both
`--thinking low` and `--thinking max`:

```
req1..req3  HIT tool-output-ids   (tool fast path, as predicted)
req4 (text) no miss, cached=live, suffix=~25  -> GREEN
```

**What this tells us (evidence, not a failure):** a fresh session whose client
and server stay in lockstep re-renders the history bit-for-bit, so the text turn
hits. The victim's `common < live` therefore requires something that broke
lockstep in that session. From FINDINGS2 the victim had, in the miss window:
(a) a **disk-snapshot load** (line 562, cr=192512) after which ~10 turns were
generated live on top of re-rendered snapshot tokens, (b) **aborted assistant
turns** + a **user steering block** + a **context_edit**, and (c) a server
restart era. None of those are in the fresh shape.

**Consequence for the test's RED baseline:** the reliable, repeatable RED is
NOT the bare two-run shape. It is one of the victim-structure variants below,
in escalation order. Until a variant goes RED, the test correctly reports GREEN
(do not treat a GREEN fresh run as a false pass or a false fix-confirmation).

## How to run (unit-test style, any time)

Prereq: server up, **one at a time** on this machine, with the probe:

```sh
cd ~/repos/ds4
DS4_CACHE_MISS_DEBUG=1 ./start-qwen38-longctx.sh > /tmp/fc-debug/server.log 2>&1 &
# wait for model load (~2-3 min at 393k); then:
python3 tests/test_responses_replay_miss.py \
    --log /tmp/fc-debug/server.log --pi /etc/profiles/per-user/ian/bin/pi \
    --model qwen3.8-flash-next-393k
```

The driver drives **real pi** (not raw HTTP) in an isolated scratch session:
run 1 = a tool task ending in a plain-text answer; run 2 (`--continue`) = a
one-line follow-up, whose request is `[history incl. text answer] + new user
message` — tail is assistant text, no trailing `function_call_output`. That
request is the miss turn. Reading the log after the run never touches a model
token: only counts and the base64 probe rows.

Why real pi and not curl: ds4 routes a request to a slot **by reuse**
(`job_slot_score` :14864 → `slot_probe_reuse_locked`); the victim's miss landed
on the slot holding the full live prefix because pi is a stable client reusing
one session. A raw HTTP client that fails to reuse evicts to a fresh slot
(`old_pos=0` → `reason=no-live-checkpoint`) — a different path, not the bug.

## Escalation ladder (forcing RED — verified order from the 2026-10-06 run)

Steps 1–2 of the original ladder are **excluded** by the calibration run
(max thinking is still GREEN; the shape is not the trigger). The RED trigger
is the victim's lockstep-breaking structure, in this order:
1. **Disk-snapshot load then text turn.** Pre-seed the disk KV cache for the
   session, force a reload (restart or evict the live slot), then drive a
   tool-run + text turn. The disk snapshot holds re-rendered tokens; the client
   re-render on top is the most likely drift source and matches the victim's
   disk-load era. This is the leading RED candidate.
2. **Inject a mid-history edit/abort** (a context_edit or an aborted turn) into
   the client's replayed history so its re-render forks from the live KV — the
   victim carried exactly this in the miss window.
3. **Replay the victim's own rendered inputs** (rebuild them from the session
   file with the `rebuild_input.py` recipe in `/tmp/fc-debug/`) through the same
   log-tail harness — the faithful, deterministic RED baseline.
4. Last resort: continue the actual victim session against a capture server.

The capture (probe window) and the RED baseline use the same run; the `!=`
rows from the first RED are the empirical cause the owner asked for, and they
constrain the fix (a drift in reasoning re-render ≠ a drift in the recovered
tool call ≠ a mutable id/timestamp).

## After the fix

- Same command → expect **exit 0**; the text-turn block shows
  `ctx=<live>..<prompt>:<small>` and no miss line.
- Confirm on **two consecutive** text turns.
- Keep the test in the repo; re-run on any change touching
  `slot_probe_reuse_locked`, `build_live_prompt_suffix`,
  `responses_prepare_live_continuation`, or the checkpoint/rewrite paths.

## Guardrails (carried from the incident)

- Never restart a live server without the owner's go. A capture server is a
  fresh start on 8080 (owner confirmed go for this capture, 2026-10-06).
- Never compose a model chat-template/special marker in plaintext anywhere
  output reaches a tokenizer (reasoning included). The probe and this test
  carry bytes as base64 and print decoded text truncated, inside the process.
- Disk KV cache is near full (116/120 GiB): a stale-snapshot disk load is
  normal-but-expensive, not the bug. The bug is the token mismatch that
  *forces* the fallback.
