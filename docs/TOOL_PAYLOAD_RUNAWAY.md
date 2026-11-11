# TOOL_PAYLOAD_RUNAWAY — an unclosed tool payload decodes to the context ceiling

**Status: OPEN. Filed 17 Oct 2026 from a live pi session. No code changed.**
Distinct from Bug 2 (`RESPONSES_CACHE_MISS.md`); this event *created* a Bug 2 fork as a side effect.

## Symptom

One `/v1/responses` request generated **62,100 tokens in 1,582 s** and never produced a tool call:

```
18:29:34 chat ctx=260145..260192:47 RESPPROTO TOOLS prompt done
18:29:35 gen=50   ... THINKING
18:29:40 gen=250  ... DSML_START          <- payload opens
...                ... DSML_START         <- 61,850 more tokens, same state
18:55:57 gen=62100 ... DSML_START 1582.874s   <- user aborted in pi
```

No `DSML_END`, no `tool calls` line, no `finish=` line. Healthy calls in the same log close at **225** and **1,779** tokens. The client saw nothing: a tool call is materialized only after the closing marker.

## Why nothing stopped it (verified in source)

| Anchor | Finding |
|---|---|
| `ds4_server.c:15620` | `.default_tokens = 393216` — the default generation cap **is the whole context**. Live server (pid 27037) passes **no `--tokens`**. |
| `ds4_server.c:13973` | Loop bounds are only `!g_stop_requested && !job_cancelled(j) && completion < max_tokens && session_pos < ctx`. Nothing tool-specific. |
| `ds4_server.c:7373-7380` | `dsml_decode_tracker` has `mode`, `decode`, `pos`, JSON flags — **no byte/token budget**. `:7547` `dsml_decode_state_is_tool()` is precisely the state it sat in. |
| `ds4_server.c:13978` | Inside a tool payload `kv_cache_maybe_store_continued()` is **skipped** — 62k tokens stored no checkpoint, so nothing was salvageable afterwards. |

At 322,292 tokens with `--ctx 393216` there were **~70,900 tokens ≈ 30 more minutes** of headroom. The abort was the only thing that ended it.

## The abort works; its log did not appear

`wait_for_job_or_disconnect()` (`ds4_server.c:15298-15312`) polls the client socket every 100 ms → `server_cancel_job()`. Measured: generation stopped **25 tokens ≈ 0.6 s** after the last logged chunk (`live=322317` vs ctx end `322,292`), so cancellation propagated.

**But the user confirms no `client disconnected` line appeared**, and `ds4_server.c:14700-14712` is supposed to log exactly that at `DS4_LOG_DEFAULT`, plus `finish=error` at `DS4_LOG_GENERATION`. Two candidate explanations, unresolved:

1. `job_cancelled(j)` was never set — cancellation came from a path that does not reach the 14700 block (then: what stopped the decode?).
2. The block ran but `server_log` filtered it below console level for this run (no `--trace`; server logs to the terminal, no file).

Decisive probe: reproduce with `--trace` and `trace_event()` around the cancel path, or add a `DS4_LOG_DEFAULT` line inside `server_cancel_job()` itself.

## Unknown: degeneration vs missed terminator

The 62k tokens were never persisted (`.pi/sessions/2026-10-17T23-55-44-323Z_*.jsonl`: largest record 492 KB is the system record; abort records are 1.3 KB). So the payload cannot be inspected. Either the model degenerated inside the payload, or it emitted a closing marker the tracker did not recognize. `--trace` on a reproduction settles it.

## Fix, minimal

1. `payload_bytes` counter in `dsml_decode_tracker`; stop the decode past a threshold with an explicit finish reason instead of silence.
2. One `DS4_LOG_DEFAULT` WARNING at a soft threshold (~4 KiB of open payload) so the terminal shows the anomaly *while it happens*.
3. Reconsider skipping `kv_cache_maybe_store_continued()` for long payloads — today a runaway is pure loss and forces the next turn down the Bug 2 heal path.
4. Stopgap available now: set `--tokens` in the pi-facing start script so a runaway is capped by config, not by ctx.

## Reproduction shape

A tool-enabled request whose payload never closes: a long `write`-style tool call at deep context (~260k), or a synthetic client that keeps the server inside `DSML_START`. Verdict: `gen > threshold` with no `DSML_END` and no `finish=` line. Same harness style as `tests/test_responses_replay_miss.py`.

## Evidence

- Server log 17 Oct 2026 18:29:34–18:55:57 (terminal, not persisted).
- Recovery chain after the abort: `live kv cache miss … live=322317 prompt=260290 common=182859 reason=token-mismatch` → heal → `prefill-failed` → disk cache discarded → second re-prefill 92,380 tokens in 114.6 s → 8,340 MiB KV store. One abort cost ~3 minutes.
- Victim session: `Personal-Notes/.pi/sessions/2026-10-17T23-55-44-323Z_01a14c4a-*.jsonl`.
