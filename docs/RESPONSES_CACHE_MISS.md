# ds4 `/v1/responses` — project intake & KV-cache-miss handoff

> [!summary] Status in one line
> Bug 1 (permanent 400) is **fixed and on the branch** `fix/responses-replay-status-tolerance` (commit `10e2a71`). Bug 2 (live KV-cache miss on every turn of a long pi session) is **reproduced + probe-captured**: the mechanism is confirmed from the victim's own server log (a forked client history freezes `common` mid-history and the miss path re-prefills from token 0 every turn — see `RESPONSES_REPLAY_MISS_TEST.md`), and the fix is **specified but not yet built**. This doc is the handoff so a fresh session can continue without re-deriving it.

**Read this top-to-bottom before touching `ds4_server.c`.**

---

## 1. What ds4 is (context, 60 seconds)

- Serving stack the agent runs itself: pi → `http://localhost:8080/v1/responses` (provider `localhost`, api `openai-responses`), model `qwen3.8-flash-next` (Q4 GGUF) on Metal, MTP speculative decoding.
- One server: `ds4_server.c` (~20k lines, single file). Engine: `ds4.c`. Build: `build.sh` (clang `-O3 -ffast-math`, `make`).
- KV cache has **two tiers**:
  - **live** — in-memory, per session slot. This is what "hits" normally.
  - **disk** — snapshots in `~/.ds4/kv-cache/`, filename = content hash, `--kv-disk-space-mb 122880` (~120 GiB; was ~116 GiB used at write time). Loaded as a fallback when the live prefix doesn't match.
- Serving flags of record: `--ctx 393216 --port 8080 --mtp --kv-disk-dir ~/.ds4/kv-cache --kv-disk-space-mb 122880 --kv-cache-min-tokens 4096 --kv-cache-cold-max-tokens 393216 --kv-cache-continued-interval-tokens 32768 --kv-cache-reject-different-quant --prefill-chunk 8192 --tool-memory-max-ids 32768`. **No `--trace`** in the current run (see §7 — trace is the cheap escape hatch).

---

## 2. Bug 1 — permanent 400 `invalid JSON request` (FIXED, on the branch)

**Symptom.** After one turn where a tool call is recovered from *unclosed* reasoning, *every* subsequent `/v1/responses` request returned HTTP 400 `{"message":"invalid JSON request","type":"invalid_request_error"}`. Permanent — `continue` could never recover.

**Root cause (round-trip violation, four files).**
1. **Emit (ds4):** `ds4_server.c:~8348` — a reasoning item is emitted with `status:"incomplete"` when the reasoning block did not close naturally (also `~8689`, `~8953–8964` for message items on length/error finish). This is *deliberate* per the code comment.
2. **Store (pi):** `openai-responses-shared.ts:~690` — `thinkingSignature = JSON.stringify(item)`, the whole item **including `status`**.
3. **Replay (pi):** `openai-responses-shared.ts:~263–265` — `JSON.parse(...)` → pushed back into `input` verbatim, every request, forever.
4. **Reject (ds4):** `ds4_server.c:~4921` — any replayed item whose `status != "completed"` → `return false` → `goto bad` → 400 on the **whole request**.

**The fix (commit `10e2a71`, `ds4_server.c` only, +21/−46).** Flips two parse-time gates from *reject → accept*:
- Non-terminal `status` (`in_progress`/`incomplete`/`failed`): **accept and clear the local**, log a WARNING, fall through. (Old code freed 15 locals and `return false`.)
- Unknown item `type` (the `!is_bookkeeping` catch-all): **drop that one item** with a WARNING, keep the session alive. (Old code hard-failed the whole parse.)

**Verified:** the 4 previously-fatal shapes (the exact victim bytes + 3 variants) now parse OK and generate end-to-end (HTTP 200); the real victim session continued. Evidence: `/tmp/fc-debug/PR-REPORT.md`, `/tmp/fc-debug/pr.diff`, `/tmp/fc-debug/FINDINGS.md`.

> [!important] This fix is **content-inert with respect to tokenization**
> The only thing it mutates is a *local* `status_str` that is freed and **never feeds prompt rendering** (rendering reads `summary`/`content`/`arguments`). It does not re-serialize, reorder, re-escape, drop content fields, or synthesize ids. **It did not cause Bug 2.** It made the session *runnable* (previously 400), which is what made Bug 2 *observable*. Anyone reading "cache broke right after the 400 patch" should not conclude the patch is the cause.

---

## 3. Bug 2 — live KV-cache miss every turn (OPEN — fix this)

**Symptom.** Long pi session (ctx ~300K) re-prefills ~112K tokens *every turn* instead of hitting the live KV. Key log line:

```
live kv cache miss RESPPROTO live=304375 prompt=304396 common=298741 reason=token-mismatch
```
Fallback then loads the **stale disk snapshot** and re-prefills the gap: `304396 − 192512 = 111,884` tokens.

**The anomaly that localizes it.** The prompt grew only **+21 tokens** over `live`, yet the common *token* prefix ends **5,634 tokens before** the live end (`304375 − 298741`). So the re-sent history — which should match the live prefix token-for-token — **diverges from the live KV mid-history.** That is the whole bug, in one line.

**Victim + verified math** (session `01a1059a`, pirot frame-copilot, `qwen3.8-flash-next-393k`, ctx 393216; transcript `Personal-Notes/.pi/sessions/2026-10-04T06-29-06-380Z_01a1059a-…jsonl`):

| turn | role shape | cr | note |
|---|---|---|---|
| 562 | disk snapshot **loaded** | 192512 | first turn of the "disk era"; tot=298741 |
| 564–572 | tool-call turns | tracks prior tot | all **HITS** |
| 574 | thinking+text, **no tool call** (final answer) | 303606 | tot=304375 = `live` |
| **next** | **text turn** (no trailing `function_call_output`) | — | **MISS** `common=298741`, prompt=304396 |

So the miss is the **first *text* turn after a run of *tool-call* turns**, and `common=298741` is exactly where the disk-loaded era's generation ended.

**Mechanism (what's verified vs. what's hypothesis — be precise when you continue):**
- **Verified (source + transcript):** (a) tool-call turns take a **call_id fast path** (`responses_live_matches_request_locked`, `ds4_server.c:~10576`) that skips full token verification — hence "hits." (b) A text turn has no `function_call_output`, so that path is unavailable and ds4 falls to the **full token-prefix compare** (`ds4_session_common_prefix`, `ds4.c:76434`) — which misses at 298741. (c) The divergence is mid-history (5,634 tokens back), not at the tail.
- **Leading hypothesis (needs the debug log to confirm the exact tokens):** the live KV holds the **raw sampled bytes** of each prior turn (the model's exact think-block text + exact tool-call tokens), while pi **re-renders** every prior turn back into the chat template on each request (reasoning item, message item, `function_call`, `function_call_output`). That re-render is **not bit-exact** with the raw generation. The 5,634-token gap is the accumulated drift that the tool-call fast path had been *masking*; the first text turn exposes it.
- **Open (the two things the debug log resolves):** (1) *which* field re-renders differently — the reasoning/thinking text (re-render vs. raw, incl. any truncation/whitespace/markers), the recovered tool call, or something mutable like a timestamp; (2) *why the fast path didn't engage* on the text turn (confirm it truly fell to the token compare, and at which tier).

**Why "regression after the 400 patch" is a misattribution.** Pre-patch the session 400'd (dead). Post-patch it runs, and its *pre-existing* round-trip drift becomes visible as cache misses. The patch's content is inert (see §2 note). Do not "revert the patch to test" — it will just 400 again.

**Fix direction (recommended, in ds4 — not yet built):** make the Responses path **canonicalize the live checkpoint on text turns too.** The machinery already exists for the chat/completions tool path: `canonicalize_tool_checkpoint` (`ds4_server.c:~12942`) tokenizes the *rendered* (canonical) prompt, finds `common`, and rewrites the live session from `common` via `ds4_session_rewrite_from_common` so the KV matches what the client will re-send. The Responses text-turn path skips this. The fix is to run the same "rewrite-from-common to the canonical render" for Responses text turns, so the next request's re-render matches the live prefix → hit.
- **Alternative (pi-side, larger blast radius):** make pi replay the exact raw bytes ds4 generated instead of re-rendering. Correct in principle but touches pi, not ds4; the user wants it fixed in ds4.
- **Do not** "just re-prefill and accept" — that is the current behavior and it's the cost.

**Probe is built** (commit `c13f616`): an env-gated token-window dump at the miss site (`DS4_CACHE_MISS_DEBUG=1`). On every `live kv cache miss` it logs the first-diff index plus, for ±32 tokens around it, the live id, the prompt id, `match===/!=`, and the **base64** of each side's decoded token text (base64 so raw special-token bytes never hit the log stream). No behavior change unless the env var is set.

**To run it:** restart the server with `DS4_CACHE_MISS_DEBUG=1` in its environment (operator-controlled; do not restart without the go), drive one miss (tool calls → final text turn), then `grep CACHEMISS_DEBUG <log>`. The `first_diff=` line and the `!=` rows name the divergent item exactly.

**NOT yet done (do not assume it is):**
- [x] Debug log at the mismatch site (built, `c13f616`).
- [x] Live miss captured through the probe — done 2026-10-06 (`force_http.py` fork repro; `server-capture.log` shows `reason=token-mismatch` + the ±32 window naming the fork). See `RESPONSES_REPLAY_MISS_TEST.md` § Calibration.
- [x] Divergence confirmed: the client's re-rendered **history** forks from the live KV mid-history (a history rewrite/compaction, e.g. the victim's aborted-turn `status:incomplete` reasoning items + short re-sent histories). Not a mutable id, not a single field.
- [x] **The fix, built and tested** — `b93dd54` (branch `fix/responses-replay-status-tolerance`). One guarded block in the Responses miss path (`ds4_server.c` :13649+). Guard: Responses protocol, no multimodal, `0 < common < live` and `common < prompt` (a mid-history fork). On that shape: (1) skip the evict-store of the forked checkpoint, (2) after a disk load verify the loaded tokens are still a lockstep prefix of the client's canonical prompt — on a fork, discard the payload (`kv_cache_discard_failed_disk_entry`) and let the canonical full-prompt sync heal the checkpoint, (3) the fork turn's prefill becomes a full heal-sync of the client's re-render, and the **next** turn continues in lockstep. **Why this shape and not the spec'd `ds4_session_rewrite_from_common` rebase:** the rewrite function can never mutate on a mid-fork — `ds4_session_rewrite_requires_rebuild` (ds4.c:76371) returns true whenever `common < live`, so it reports `REBUILD_NEEDED` without touching the session, and the qwen4 GPU backend's `ds4_session_sync_internal` (ds4.c:75279) resets its graph on any non-prefix prompt (no mid-history resume). A "rebase" is therefore equivalent to the full heal-sync that happens when the fork is not re-seeded. The persistence (the victim's 40-min frozen `common`) was the re-seeding: the miss path's `kv_cache_store_current(s, slot, "evict")` wrote the forked checkpoint to disk and the next turn loaded it back. **Verification** (all on `qwen3.8-flash-next-393k` @ 393k, capture server with `DS4_CACHE_MISS_DEBUG=1`): fork repro small + at scale (>4096 tokens, disk era) → fork turn misses once + heal prefill, next turns `HIT visible-prefix` in lockstep, no frozen `common`; forked-disk-guard repro (era with thinking → restart shutdown-store → forked disk load) → guard line fires, payload discarded, next turn HIT; fresh in-lockstep harness (`tests/test_responses_replay_miss.py`) stays GREEN (exit 0, suffix=25). Repro scripts in `/tmp/fc-debug/` (volatile): `force_http.py`, `fork_think_scale.py`, `fork_disk_guard.py` (two-phase, restart between). See `Projects/ds4/progress.md` (vault) for the full record.

## 3.5. Upstream PR — submitted as DRAFT (2026-10-07)

**PR:** `antirez/ds4#1194` — https://github.com/antirez/ds4/pull/1194 (draft, 1 commit).

- **Fork/branch:** `isgallagher/ds4` branch `pr/responses-fork-heal`, single commit `ce9fd0b` (author: Ian Gallagher, GitHub noreply id) — a cherry-pick of the fix onto clean `origin/main` (`0aaea5a`). The PR branch carries **only the code change** (`ds4_server.c`, +56/−5); no probe, no Bug-1 parser change, no private docs, no client-specific test harness.
- **PR shape (why one commit, code-only):** the fork-heal is self-contained — it references only pre-existing symbols (`ds4_session_common_prefix`, `kv_cache_try_load`, `kv_cache_discard_failed_disk_entry`), cherry-picks clean onto `origin/main`, and builds warning-free there. The internal commit history (Bug-1, probe, private intake docs, `pi`-driven harness) is project work, not an upstream change.
- **PR code = commit `ce9fd0b` on the fork, not `b93dd54` on the fix branch.** Difference: (1) comments reworded — no "Bug 2" / "victim" framing; (2) one added KVCACHE log line at the heal decision (`responses live checkpoint forks from client re-render`) so an operator can see the heal engage even when no disk payload is involved; (3) upstream-style commit message (imperative subject, mechanism body, machine/backend/commands per `CONTRIBUTING.md`). The local fix branch was synced to this exact code (`c8217e2` on `fix/responses-replay-status-tolerance`) so one canonical variant exists.
- **Verification of the PR binary itself** (not just the fix-branch build) — Apple M5 Max, Metal, Qwen3.8-Flash-Next Q4 gguf, ctx 393216:
  - `fork_think_scale.py` (disk-era fork, thinking on): fork turn misses once + heal (`common=62`), R4/R5 `HIT visible-prefix` in lockstep; heal log line present.
  - `fork_disk_guard.py` (two-phase around a restart): forked `responses-visible` payload loaded → **guard fired** (`loaded=4795 common=4758` → discard + heal) → next turn HIT.
  - `tests/test_responses_replay_miss.py` (run from the fix branch; not included in the PR): **GREEN**, exit 0, text turn `suffix=25`.
  - `make clean; make; ./ds4_test --server` → passes (this suite `#include`s `ds4_server.c`, so it compiles the change).
  - `make cpu` → builds (portability check).
- **To make it ready:** `gh pr ready 1194 --repo antirez/ds4` (or via the web UI). Owner has not asked to notify upstream; it stays a draft until then.
- **Push mechanics (this box):** SSH to github.com times out (port 443); the global `url.git@github.com:.insteadOf` rewrite forces SSH even for HTTPS remotes. Push with `git -c credential.helper= push https://isgallagher:$(gh auth token)@github.com/isgallagher/ds4.git <branch>`. The `fork` remote is set to the HTTPS URL but the rewrite still bites — use the one-liner above.
- **If the PR needs changes** (reviewer feedback): work on `pr/responses-fork-heal` (it is the fork's branch; `git push` it with the one-liner) — `gh pr edit 1194` for the body; the body is saved at `/tmp/fc-debug/pr-body.md` (volatile — copy it if needed).

---

## 4. Build / run / reproduce / verify

- **Build:** `cd ~/repos/ds4 && ./build.sh` (produces `./ds4-server`). Already built this session; the working tree is on the branch with the 400 fix.
- **Do NOT restart the running server until the operator says so** (they are mid-session on it). Build freely; restart is a gated action.
- **Reproduce the miss:** continue the victim session (or any pi session on `localhost`) past ~250K ctx with a run of tool calls followed by a final text turn. Watch for `live kv cache miss … reason=token-mismatch` + a `disk … tokens=… ` load + a ~100K re-prefill.
- **Verify a fix:** two consecutive turns must show `common == previous live` (i.e. `reason` is not `token-mismatch`) and prefill drops to the few hundred *new* tokens (healthy line looks like `cached=303606 prompt=303837`, not a 111K prefill).
- **Cheap instrumentation that needs no restart gymnastics:** relaunch with `--trace <file>` (flag exists at `ds4_server.c:~15642`). The trace writes the raw request JSON, the rendered prompt, the generated text, **and** a `--- cache decision ---` block with `live_prompt_common` + a **token window around the first mismatch** (ids + decoded text) — `trace_write_cache_diag`, `ds4_server.c:~11864`. That window *is* the STEP-2 "what item sits at 298741" answer, already implemented. If `--trace` is enough, no new debug code is needed.

---

## 5. Evidence & file inventory

| Path | What |
|---|---|
| `/tmp/fc-debug/FINDINGS.md` | Bug 1 full investigation (raise sites, truncation ladder, round-trip, the real victim bytes) |
| `/tmp/fc-debug/PR-REPORT.md` | Bug 1 fix report (root cause, diff, verification table) |
| `/tmp/fc-debug/pr.diff` | The actual Bug 1 diff (`ds4_server.c` only) |
| `/tmp/fc-debug/FINDINGS2.md` | Bug 2 verified-state notes (this session) |
| `/tmp/fc-debug/proxy2.py` | Logging TCP proxy 8081→8080, dumps each body to `req-<n>.json` |
| `~/repos/ds4` branch `fix/responses-replay-status-tolerance` | Bug 1 fix (commit `10e2a71`), 1 ahead of `main`, **unpushed** |
| Victim transcript | `Personal-Notes/.pi/sessions/2026-10-04T06-29-06-380Z_01a1059a-14cb-75c9-aaa9-daf6aeaa103b.jsonl` |

---

## 6. Next steps (ordered, smallest-first)

1. **Get the token window** (resolves hypothesis → fact): relaunch one instance with `--trace` (or add a `DS4_…`-gated log at the `live kv cache miss` site, `ds4_server.c:~13558`) and capture one text-turn miss. Read `first_mismatch_token` + the ±8 token window. Confirm which item/field diverges at 298741.
2. **Implement the canonicalize-on-text-turn fix** (§3, recommended direction) on the same branch. Minimal diff; guard so it's a no-op when `common` already equals the live end.
3. **Build** (`./build.sh`), **reproduce, confirm** two consecutive turns show `common == previous live` and prefill collapses to the new-token delta.
4. **Commit to the branch** (both fixes travel together, per operator). Push only on request.

---

## 7. Operational guardrails (learned the hard way this session)

- **The agent that reasons about the model's chat-template/think markers will truncate its own turn** if it composes those literal sequences in reasoning or prose. Refer to them abstractly ("the thinking open/close markers", "the assistant role token") or, if a value is needed, as base64 — never spell the full marker sequences in a tool call, file write, or reasoning. This doc deliberately does not.
- **The running server is someone's live session.** Build freely; **do not restart it** without the operator's go.
- **Disk cache is ~full** (116/120 GiB). A "stale snapshot" load is normal-but-expensive; don't chase disk-full as the bug — the bug is the token mismatch that *forces* the disk fallback.

## 8. Multi-client residency (2026-10-29) — same symptom, different cause

The sections above are about **one** client whose history forks. The 2026-10-29
capture is the same log signature — `live kv cache miss … reason=token-mismatch`
with a tiny `common` — from a different mechanism: **two clients, one resident
session.**

| Evidence (2026-10-29, single-session server) | Value |
|---|---|
| Shared prefix found on switch | `common=6897` — the system + tool prefix only |
| Re-prefill after a discarded checkpoint | 307,066 tokens in **436.664 s** |
| Same, other conversation | 140,796 tokens in **182.213 s** |
| Same switch class with a warm cache | 2,494 tokens in **4.459 s** |
| Decode at 334k context | 33–37 t/s — the math was never the problem |

Four mechanisms, each addressed separately:

1. **One resident session evicts the peer's live KV on every turn.** Fix:
   `--batched-session N`. The router scores a slot by the prefix it can reuse and
   makes an active peer slot the last eviction victim.
2. **The fork guard (B2) discarded valid `token-text` checkpoints.** A
   `token-text` payload is byte-verified by the loader, so comparing token ids
   produced false positives — it threw away the long spliced checkpoint and kept a
   short fresh one. Fix: `0007` narrows the guard to visible-keyed checkpoints,
   which genuinely can hide a fork because they omit hidden reasoning.
3. **The near-tail pool could not hold two frontiers.** It is capped
   independently of the disk budget at `min(budget/8, 16 GiB)` and holds two
   entries; a 393k checkpoint is ~12.3 GiB, so no budget made room for two
   clients. Fix: `0009` sizes it per resident session, and `0007` writes the
   departing frontier as an `evict` **anchor**, which the tail prune never touches.
4. **A cancelled prefill deleted the payload it had loaded, and logged as
   corruption.** Fix: `0008` gives the three discard sites distinct reasons —
   `forked-payload`, `*-sync-failed`, `cancelled-during-*`.

> [!warning] The guardrail in §7 was violated in the session that wrote this section
> Four turns were truncated by composing the chat-template marker literals while
> reasoning about B2's key material — exactly what §7 warns about, and the warning
> was already in this file. The fix is not a stronger warning: those characters
> must not appear in agent output **or reasoning** at all, because reasoning
> streams into the transcript. Files that carry them as literals get touched via
> computed indices or existing constants, and inspection returns line numbers,
> lengths and counts instead of bytes.

**Verification state of the fix set:** built clean on upstream `c97964b`,
`ds4_test --server` ok, `test-kvstore-near-tail` ok including the new per-session
policy cases, and the installed binary artifact-confirmed by string probe.

## 9. Live smoke — two simultaneous sessions (2026-10-31 15:36–16:02) **PASS**

Profile: `start-qwen38-batched-vision.sh` — ctx 262144, `--batched-session 2`,
mmproj on, KV budget 245760 MiB, `cold_max=262144`. Disk tier was **emptied before
the run**, so every conversation started from zero; that is the harshest possible
start and it is why the first turn of each conversation is expensive.

| Observation | Value | Reading |
|---|---|---|
| Startup | `batched mode enabled resident_sessions=2 prefill_quantum=2048 mixed_prefill_quantum=128` | residency active |
| MTP | no *disabled while batching* line | `qwen4_batch_mtp` true on Metal |
| Memory | planned 89.30 GiB; server: `2 resident sessions … 39.15 GiB, or 27.91 GiB when the model shares one prefill workspace`; measured **RSS 92.4 GiB** | fits the 116 GiB wired limit |
| Cold turn, 220,200 tok | **269.506 s** (~817 t/s) | unavoidable: empty disk, empty live tier |
| Cold turn, 112,292 tok | **125.595 s** (~894 t/s) | second conversation, second slot |
| Every turn after | **0.245 s – 4.224 s** | the shape this whole effort was for |
| `kv cache stored` | 11 stores, ladder 32,768 → 229,376 incl. **112,292** (the other conversation's frontier) | both conversations checkpointing |
| `kv cache discarded` | **0** | no payload deleted all run |
| `forked-payload` / `cancelled-during-*` | 0 / 0 | B7 reasons never fired on a healthy run |
| `discarding and healing` | **1**, at the second session's first turn, then silent | heal fired once, cost nothing |
| `live kv cache miss` | one `common=6897`, then six `common=41` | see below |

**What `common=6897` means.** It is the shared prefix of two pi-harness sessions —
system prompt plus tool scaffolding. The router scored the other slot as reusable,
matched only that prefix, and missed. It appeared **once** and did not recur, which
is the pass condition: residency held, and the number is the floor, not a leak.
The six `common=41` misses are *different, shorter* conversations that genuinely
share ~41 tokens with whatever was resident — correct behaviour, not the bug.

**Caveats, stated.** The observer was one of the two clients, so the numbers are
self-observed rather than third-party. The disk tier started empty, so no disk-hit
evidence was produced — that path is still untested in the field. And the pool is
sized by **slot count**: a third long conversation beyond `SESSIONS=2` will still
evict, by design.

## 10. Escape-interrupt full re-prefill (2026-10-31 19:48) — third cause: an interrupted turn strands every handle

**Symptom.** Owner pressed escape in a pi session mid-thinking and sent the next
message 26 s later. The conversation sat 31 tokens from its live frontier; the
server re-prefilled the whole 201,688-token prompt (229 s) instead of a few dozen
tokens. Log: `~/ds4-batched.log` (pid 1031), batched-vision profile.

**Timeline (log + session file `01a18aac`, all verified).** 19:48:04 last turn's
prefill done (`prompt=201644`); ~19:48:05.7 escape — the session record shows a
thinking-only assistant turn, `stopReason: aborted`, 1849 ms; slot 1 froze at
**201675 = 201644 + 31**. 19:48:31.8 the new user message → prompt 201688 →
`live kv cache miss live=172631 prompt=201688 common=110092` → the visible-keyed
disk candidate (172094) was verified, forked, discarded → prefill from token 0.
19:48:47 the re-prefill evicted slot 1's 201675-token frontier (stored to disk on
eviction, 19:51:09).

**Two independent killers, each sufficient alone.**
1. Both cancel branches (`ds4_server.c:15193`, `:15217` in the contract tree)
   cleared every live handle — including the visible-transcript handle, the only
   tier that survives a next turn without tool-call ids. Both branches were
   **silent** (`trace_event` only, no `server_log`): this is why the Oct-17 and
   Oct-31 "missing `client disconnected`" lines never appeared — the decode loop
   stops only on stop-request or job-cancel, so the branches ran.
2. Even without the clear, the visible tier demands `live_tokens == live_pos`,
   and `responses_live_remember` fires only at completed-turn boundaries. An
   interrupted turn advances the frontier and strands the handle (201231 vs
   201675). The tier can only fire at turn boundaries.

With every tier declining on both slots, the router chose the cheapest *victim*
(slot 0, a stale 172631 checkpoint of the same conversation), missed at
common=110092, and patch 0007's guard discarded the forked disk payload
whole — the valid 110092-token common was never reused. The 110092 fork is
**token-level** (fresh full-prompt BPE vs incrementally appended continuation
tokens), not a history rewrite: the session file is append-only in the window,
and each earlier turn's `match=visible-prefix`/`tool-output-ids` proves the
visible bytes agreed at every frontier up to the abort.

**Fixes (patches 0011 + 0012, `docs/BUILD_PATCHES.md` B10/B11).** 0011: the
cancel branches remember the visible surface at the CURRENT frontier via the
turn-end builder (strict equality then holds; KV rewind is GLM-only, so the
handle must move to the frontier, not the frontier back to the handle) and log
the cancel. 0012: a forked disk payload no longer ends the disk tier — the
discard stays, the lookup retries, and the next-shorter token-exact candidate
loads. Cost ledger for this incident: actual 229 s; 0012 alone ≈ 154 s; 0011 ≈
tail only (~1 s). **Known gap:** if the client re-sends before the server
notices the disconnect (~100 ms poll), the frontier slot is still busy and
routing evicts it anyway — routing-level, deferred.

## 11. Why 0011 never fired: the cancel path is seven branches, not two (2026-11-01)

**Method.** No restart, no log. A read-only worktree at `c97964b` with the patch
sequence applied, then one pass over `generate_job_inner` enumerating every
`request_live_state_clear()` site with its guard, its enclosing function, and
whether it emits a `server_log` line. Line numbers below are that tree — the one
the live binary was built from — **before** patch 0013, so they shift once 0013
is in the sequence. Trace labels are the stable address.

| Line | Trace label | Live state | `server_log` |
|---|---|---|---|
| 14460 | cancelled during prefill (prefix sync) | cleared | none |
| 14498 | cancelled during prefill (prompt sync) | cleared | none |
| 14510 | cancelled after prefill | cleared | none |
| **15014** | **cancelled during generation after N tokens** | **cleared** | **none** |
| 15140 | cancelled while flushing generation | cleared | none |
| 15250 | cancelled during response parsing | 0011 remembers | yes (0011) |
| 15280 | cancelled before publishing response state | 0011 remembers | yes (0011) |

**15014 is the first cancel check after the decode loop**, so an interrupted turn
returns there and never reaches the two branches 0011 instruments. Two
consequences, both uncomfortable and both now recorded:

1. The *missing* `generation cancelled mid-turn` line was never a paste artifact
   and never a logging gap. The instrumented code cannot run on this path.
2. **The §10 smoke did not validate 0011.** The 23:14 (9.2 s) and 23:18 (13 s)
   recoveries came from the disk tier (0007/0012) and the memory-token tier. The
   residency claim for the escape case is open again — with 0013 as the fix.

**Why 0013 could not be a copy of 0011.** Three blockers, each read in source:

1. At 15014 the parsed fields do not exist yet (`parsed_calls` / `parsed_content`
   are declared further down), so the partial text is parsed in the new helper.
2. **A cancelled turn never commits the end-of-turn token** — the decode path
   skips it under cancel. A surface built by the completed-turn builder therefore
   ends with a marker whose token the live KV never received, and the next request
   would resume one token misaligned to its own text. That is wrong reuse, which
   the tier contract forbids, not the safe miss §10 relies on.
3. The Qwen surface builder emits reasoning text only when the turn carries tool
   calls, so it cannot describe a thinking-only interrupt at all: the KV holds
   bytes no remembered text covers.

**The shape that satisfies both the prefix rule and the token gap:** remember a
*partial* surface — prompt text plus reasoning-so-far, or plus content-so-far —
and append no marker. The remembered text stays a byte prefix of the render the
client sends next, and the tail it re-tokenizes begins with exactly the boundary
and end-of-turn tokens the cancelled turn never evaluated. A partial carrying both
reasoning and content would need the boundary marker between them to stay a
prefix, and a partial that reached a tool call would need the call markup, so both
keep the pre-fix clear. Remember what is provably a prefix; clear everything else.

## 12. The interrupt that made the cache worse: a cancelled prefill deleted its own checkpoint (2026-11-01 10:16)

**Owner report:** "I just interrupted you and send a new message" — and the log showed
the conversation re-prefilling 73,651 tokens, then a second conversation re-prefilling
112,866. Two mechanisms are visible in one window, and only the first one is the
escape case §10–§11 already covers.

**Mechanism A — the token-level re-render fork (known).**

```
10:16:20 slot 1: request reuses nothing; evicting checkpoint (139686 tokens, idle 32 s, protected)
10:16:20 live kv cache miss RESPPROTO live=139686 prompt=139187 common=69119 vision=match reason=token-mismatch
10:16:20 responses live checkpoint forks from client re-render ... common=69119; healing from canonical prompt
10:16:22 kv cache hit text RESPPROTO tokens=65536 ... file=66b524869d4ce6623b4c1dab501e3802f22f5100.kv
10:16:22 chat ctx=65536..139187:73651 ... prompt start
```

The resent prompt is **shorter** than the live frontier (139,187 vs 139,686) and diverges
at 69,119 — the same token-level class §10's V1 capture proved is not a history rewrite.
The visible tier cannot serve it, and 0013 cannot either: a handle whose frontier sits at
139,686 is beyond a 139,187-token prompt. This is what 0012's next-shorter retry is for,
and it worked — 65,536 recovered instead of prefilling from zero. Note also that a
**protected** 139,686-token checkpoint was evicted to make room; that is the routing side
of the same event, still parked.

**Mechanism B — new, and the reason it kept getting worse.**

```
10:16:57 kv cache discarded reason=cancelled-during-prefill file=66b524869d4ce6623b4c1dab501e3802f22f5100.kv
10:16:57 kv cache hit text RESPPROTO tokens=30985 ... key=responses-visible
10:16:57 chat ctx=30985..143851:112866 ... prompt start
```

**The file named at 10:16:57 is the same file that served the 65,536-token hit at
10:16:22.** The prefill was cancelled, `server_session_sync` returned non-zero, and the
prefill-failure path discarded the disk entry as though the checkpoint had failed.
Patch 0008 had given that branch an honest label — `cancelled-during-prefill` — but the
label was the only thing that branched: the `unlink()` ran either way. One escape
therefore destroyed 35k tokens of checkpoint, and the next request fell back to the
30,985-token checkpoint and re-prefilled 112,866. Each interrupt made the store
permanently worse than the last.

**Fix (patch 0014, runbook B13).** Keep the payload when the sync failed because the
client went away; keep every other part of the failure path unchanged, including the
session invalidation, because a mid-sync session is genuinely not a usable frontier. The
distinction is *who failed*: a forked payload is wrong for the prompt and must be deleted
(0007/0012); a cancelled prefill is a client that left, and its checkpoint is the cheapest
recovery for the resend that follows.
