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

**PRIMARY-SOURCE mechanism (from the victim's own server log, supersedes the
earlier "reasoning re-render drift" frame).** Four properties, all read from
`/tmp/fc-debug/patched-server.log`:

1. **The desync self-perpetuates.** From 13:10:35 onward `common` **froze at
   247203** for the rest of the era (40+ min), while `live` grew to 297K;
   every turn missed at that same frozen point, re-prefill gap growing
   4459 → 50145. A one-time drift heals on the next turn (the client re-sends
   the corrected history). A *frozen* `common` means the divergence is in
   **stable, already-in-history tokens the client keeps re-sending that no
   longer equal the live tokens** — it cannot heal on its own. The disk
   fallbacks that served those turns used `key=responses-visible` snapshots
   (13:10:39 `kv cache hit text tokens=250733 key=responses-visible`).

2. **The trigger is a client that rewrites/shrinks its effective history.**
   The era immediately before the freeze (12:31–13:10) is full of **tiny
   prompts** (8–18K) against a ~245K live, `common=4690` — the client sent
   *short* histories, not full re-sends (compaction / partial replay). The
   client's history stops being a prefix extension of the slot's live and forks
   from it. Once that lands, the continuation keeps re-prefilling the frozen
   gap every turn instead of healing.

3. **The `REUSE_RESPONSES_VISIBLE` tier is where the victim's healthy turns
   lived, and where it first degraded.** The 13:07:41 turn was
   `match=visible-prefix cached=247203` — the visible tier reuses the live
   frontier on the strength of a byte-prefix match of the *visible* transcript
   (no full token compare, so it was invisible to the compare). It started a
   long think turn; the freeze began the next turn. The visible tier is the
   fast path that masks drift on tool turns *and* the trust that a text turn
   relies on before it falls to the full compare.

4. **Aborted turns are in the replay.** Every frozen miss turn opens with
   repeated `replayed reasoning item with non-terminal status incomplete;
   accepting` — the client keeps re-sending reasoning items that never reached
   `completed` (aborted turns). This is the round-trip Bug 1's patch now
   tolerates (`status != completed` accepted, warning logged). The desync sits
   in the era those items belong to.

**This is why the controlled runs all HIT (calibration, not a pass):** none of
fresh / thinking-max / disk-load+restart+text *shrinks* the client history
mid-session, so the client and slot stay in lockstep and the text turn hits
(the forced run's log proves it: `kv cache hit text tokens=71680` then
`ctx=73930..73955:25` — only the new user message re-prefilled). Reproducing
the miss therefore requires a history rewrite (compaction or a partial/visible
replay), which `pi --print` in a fresh scratch session does not do. The token
window of a *real* miss is still what the probe must capture; the owner
confirmed the bug is general ("not only from that one victim session") and can
trigger it.

**Fix consequence:** the canonicalize-on-text-turn fix (rewrite-from-common to
the client's canonical render, `ds4_session_rewrite_from_common` :13031) must
not only make one turn hit — it must **heal the frozen desync** so the *next*
turn's `common == live` and the re-prefill stops. A fix that only fixes the
single request leaves the per-turn re-prefill.

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

## Fix status (2026-10-06, `b93dd54`)

Built and verified. The fix is the fork-heal block in the Responses miss
path (`ds4_server.c` :13649+, commit `b93dd54`): on a token-mismatch miss with
a mid-history fork (`0 < common < live`, `common < prompt`, text-only), it
(1) skips the evict-store of the forked checkpoint, (2) rejects a disk payload
whose loaded tokens fork from the client's canonical prompt
(`responses disk checkpoint forks from client re-render` log line + discard),
and (3) heals by full-syncing the client's canonical prompt so the checkpoint
becomes the client's re-render.

Verified on the capture server (`qwen3.8-flash-next-393k` @ 393k, probe on):
- **Fresh in-lockstep harness: GREEN** — exit 0, tool turns HIT, text turn
  `suffix=25` (calibration unchanged). Re-run after the fix: pass.
- **Fork repro (small + at scale >4096 tokens, disk era):** fork turn misses
  once + full heal prefill, next turns `HIT visible-prefix` in lockstep,
  no frozen `common`, no forked evict-store. Scripts: `fork_think_scale.py`
  (two-phase), `fork_disk_guard.py` (the guard's repro: era with thinking →
  restart shutdown-store → forked disk load → guard fires, payload discarded,
  next turn HIT).
- **Guard line observed live** on the disk-era fork turn (`loaded=4794
  common=4758` → discard + heal). That is the victim's exact re-load loop,
  broken.

Note on the test's own RED/GREEN contract: the fork-heal turn still logs a
`live kv cache miss … reason=token-mismatch` (the fork is a genuine
re-derivation; the fix makes it heal once instead of re-forcing every turn).
So a RED-shape turn after the fix shows: one miss line on the fork turn +
HIT on the continuation turns. A run that misses on **consecutive** turns at
the same frozen `common` is the regression this fix removes.

## Guardrails (carried from the incident)

- Never restart a live server without the owner's go. A capture server is a
  fresh start on 8080 (owner confirmed go for this capture, 2026-10-06).
- Never compose a model chat-template/special marker in plaintext anywhere
  output reaches a tokenizer (reasoning included). The probe and this test
  carry bytes as base64 and print decoded text truncated, inside the process.
- Disk KV cache is near full (116/120 GiB): a stale-snapshot disk load is
  normal-but-expensive, not the bug. The bug is the token mismatch that
  *forces* the fallback.
