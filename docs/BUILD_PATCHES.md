# ds4 — patch-based build runbook

`build.sh` + `patches/` make the local combined build reproducible: **fetch
upstream `main` → apply the upstream PR patches → apply our patches → build
`./ds4-server` → install + re-sign**, without touching the working tree or any
branch. The **patch files are the build contract**, not any branch: the build is
deterministic for a given (upstream commit + patch set).

This file is the runbook for changing that contract. Read it before editing
`build.sh`, `patches/`, or swapping the running server.

## The contract today (2026-10-22)

Two groups, applied in this order. Group A is other people's upstream PRs that
we build on while they wait for merge; group B is our own fixes.

| # | File | What | Upstream state |
|---|---|---|---|
| A1 | `patches/upstream/pr1175.patch` | validate parent history before the live tool-ID shortcut | PR #1175 @ `4e8706d`, open |
| A2 | `patches/upstream/pr1169.patch` | preserve sampled tool-call spans/IDs across checkpoint restore; align committed EOS, tails, visible keys | PR #1169 @ `395a3ed`, open |
| A3 | `patches/upstream/pr1206-integrated.patch` | preserve the Qwen Responses live frontier when the client replays an emitted final-answer reasoning summary (and when it does not) | PR #1206 @ `a08bce5`, open — **stored integrated**, see §Why A3 is not the raw PR |
| A4 | `patches/upstream/pr1200.patch` | save eligible completed text-only Qwen Responses prompts as a `near-tail` checkpoint before generation | PR #1200 @ `d18057e`, open |
| A5 | `patches/upstream/pr1221.patch` | let the memory-text tier survive images (fixes #1214) | PR #1221 @ `2b720e8`, open |
| A6 | `patches/upstream/pr1212.patch` | fix the Qwen Chat tool-turn disk checkpoint key for reasoning-echo histories (fixes #1211) — the turn persisted a reasoning-free alias, so the next return could not match it | PR #1212 @ `a05decc`, open. **Regenerated 2026-10-31 against upstream `c97964b`** — context only: upstream added lines at the same `.gitignore` spot and extended the `clean:` block, so the old file left markers; the new one applies clean after A1–A4 |
| A7 | `patches/upstream/pr1216.patch` | pick the **longest** text-prefix disk checkpoint in one pass, and stop re-hashing the prompt per candidate | PR #1216 @ `402c80b`, open |
| A8 | `patches/upstream/pr1197.patch` | accept WebP images on macOS through ImageIO (a pasted WebP used to answer a generic 400) | PR #1197 @ `cea545e`, open |
| B1 | `patches/0001-responses-accept-nonterminal-status.patch` | accept non-terminal item status + drop unknown item types on Responses replay (the "400 API" fix) | ours, no PR |
| B2 | `patches/0002-responses-heal-forked-checkpoint.patch` | fork-heal in the miss path | ours, **PR antirez/ds4#1194** (draft) |
| B3 | `patches/0003-responses-cache-miss-probe.patch` | `DS4_CACHE_MISS_DEBUG=1` first-diff window on a miss (diagnostic only) | ours, diagnostic |
| B4 | `patches/0004-responses-vision-block-continuation.patch` | copy the full vision block into the live KV continuation suffix | ours, no PR |
| B5 | `patches/0006-vision-embedding-cache-fingerprint-key.patch` | key the vision embedding cache on the pixel fingerprint (SHA-256 of decoded width/height/RGB, the KV tier's identity) instead of exact client bytes, so a client re-encoding the same pixels turn to turn still hits | ours, no PR |
| B6 | `patches/0007-responses-fork-guard-visible-keys.patch` | narrow the B2 fork guard to **visible-keyed** checkpoints, load side and store side: a `token-text` payload is byte-verified against the incoming prompt by the loader, so the token-id compare produced false positives — it discarded long spliced checkpoints and kept short fresh ones. Measured need: 2026-10-29, two clients on one resident session, 294,912-token payload discarded → 436.664 s re-prefill vs 4.459 s for the same switch class | ours, no PR (supersedes nothing; B2 stays the visible-key safety net) |
| B7 | `patches/0008-kv-discard-reason-per-decision-site.patch` | `kv_cache_discard_disk_entry(s, slot, path, reason)` — the three discard sites get distinct reasons (`forked-payload`, `cold-prefix-sync-failed`, `prompt-sync-failed`, `cancelled-during-*`) instead of one `prefill-failed`. Diagnostic only: same unlink, same invalidation | ours, no PR |
| B8 | `patches/0009-kv-tail-pool-sizes-with-resident-sessions.patch` | near-tail pool sized per resident session: cap 16 GiB → 16 GiB × sessions, entry limit 2 → 2 × sessions, from `ds4_kvstore.resident_sessions` set to `slot_count`. `0` reads as `1`, so single-session behaviour is unchanged and A4's test passes untouched. Extends `tests/test_kvstore_near_tail` with the policy cases (unset → 16 GiB at a 240 GiB budget, 2 sessions → 30 GiB, 3 and 8 → 30 GiB, share binds). **Touches 4 files** (`ds4_kvstore.h/.c`, `ds4_server.c`, the test) — the deviation from "local patches touch `ds4_server.c` only" is because the sizing lives in the store | ours, no PR |
| B9 | `patches/0010-kvstore-test-stub-payload-bytes.patch` | stub `ds4_session_payload_bytes` in A6's model-free test so it links once A4 is in the tree (A4 made the store call it; the symbol lives in `ds4.c`, which that target does not link). A4 ships the same stub in its own test | ours, no PR |
| B10 | `patches/0011-responses-cancel-remember-visible.patch` | a cancelled Responses turn now **remembers** the visible surface at the current frontier (via the turn-end builder) instead of clearing every live handle, and both cancel branches log. Fixes the escape-and-continue full re-prefill (2026-10-31 19:48: 201,688 tokens / 229 s for a conversation 31 tokens from its frontier) and the two-sessions-old "missing disconnect line" mystery (the branches were silent). No KV rewind — rewind is GLM-only; remembering at the frontier keeps the visible tier's strict `live_tokens == live_pos`. Mismatching clients miss safely, as before the fix. Tests: probe case 8 + `test_responses_cancel_release_live`. **Scope corrected 2026-11-01 by B12: the escape path returns at an earlier branch and never reaches these two, so B10 does not serve the escape case — it serves a cancel that arrives after the decode loop finished. The "missing disconnect line" finding stands (five branches are still silent)** | ours, no PR |
| B11 | `patches/0012-kv-fork-next-shorter-candidate.patch` | a forked visible-keyed disk payload no longer ends the disk tier: the 0007 discard stays (protective), the lookup is retried (the refresh inside rescans the store directory, so the discarded file is never offered again), and the next-shorter candidate gets its own lockstep check — a pre-fork ladder checkpoint is token-exact and loads. Bounds any re-render fork at prompt−frontier (2026-10-31 shape: 229 s → ~154 s). Bounded at 4 attempts; live-smoke-verified, same verification shape as B6 | ours, no PR |
| B12 | `patches/0013-responses-cancel-remember-partial-visible.patch` | **the branch the escape actually takes.** `generate_job_inner` has seven `request_live_state_clear()` sites under `job_cancelled`; an interrupted decode returns at the first one after the loop ("cancelled during generation after N tokens"), which B10 left as a silent clear — so B10's log line could never appear for an escape, and the 23:14 / 23:18 recoveries were the disk and memory-token tiers. That branch cannot reuse B10's helper either: the completed-turn builder closes the surface with the model's end-of-turn marker, and a cancelled turn never commits that token, so the handle would claim one token more than the live KV holds — **wrong reuse, not the safe miss**. This patch remembers a **partial** surface (prompt text + reasoning-so-far, or + content-so-far, no marker appended) so the next request re-tokenizes the boundary and end-of-turn tokens onto the live KV; single-surface partials only, everything else keeps the clear. The parser is asked with the closed-thinking requirement off, because the cancelled turn is unclosed by definition. Test: `test_responses_cancel_release_live_partial`, mutation-checked | ours, no PR |
| B13 | `patches/0014-kv-keep-payload-on-cancelled-prefill.patch` | **a cancelled prefill deleted a good checkpoint.** The prefill failure path unlinked the disk payload it had just loaded; B8 gave the cancel its own reason label, but the unlink stayed. Measured 2026-11-01 10:16: a 65,536-token hit from `66b52486…kv`, the prefill cancelled, then the same file unlinked → the next request resumed at 30,985 and re-prefilled **112,866** tokens (~5 min). Every interrupt made the store permanently worse, which is what an owner experiences as "it got slower after I pressed escape". Now the cancel path keeps the payload and runs the same session and schedule bookkeeping (the mid-sync session is still invalidated), logging `kv cache entry kept reason=cancelled-*`. The `forked-payload` discard stays — that payload really is wrong for the prompt | ours, no PR |
| B14 | `patches/0015-vision-embedding-cache-sized-from-flag.patch` | **the vision embedding cache could not hold the conversation, so it re-encoded every image on every turn.** B5 made the key the pixel fingerprint and dropped the client bytes from the accounting, which left `SERVER_IMAGE_CACHE_BYTES` (128 MiB, compile-time) holding **13 images of 1000 tokens** at the 2560-wide fp32 row width (10,240,000 B each). A session that reaches 15 screenshots cannot fit its own working set, and because every request replays every image in history order the LRU victim is always the next image that same request asks for, so one over-capacity step is a **permanent full-set re-encode**, not a one-image degradation. Measured 2026-11-14 (one agent session, 3 h log): 14 hits + 1 encode per turn while the cache climbed to 13,092 of the 13,107 available token-rows, then **0 hits and 15 encodes per turn** (79 s and 83 s of encoder time for requests whose model work was 1.5 s prefill + 22 s decode, with the KV hitting every time: `cached=228077 prompt=228332`). Now: entry cap `32 -> SERVER_MAX_IMAGES` (256, so the entry limit can never bind before the byte limit), and the budget is `--vision-cache-mb N` (default **1024** = ~100 images; `0` disables). Startup logs `vision embedding cache %zu MiB, %d entries`. Tests: `test_server_image_embedding_cache_thrash` (over-budget => every round re-encodes every image, forever; fits-budget => encodes stop after round 1) and `test_vision_cache_mb_option` (default parsed as the literal 1024, and the default must hold the 15x1000-token set that failed). Both mutation-checked: lowering the default to 128 fails 2 assertions; a `put` that ignores its budget fails the thrash bound. **Deviation from "local patches touch `ds4_server.c` only": one line in `ds4_help.c`, so the flag appears in `--help`** | ours, no PR |
| B15 | `patches/0016-kv-vision-identity-in-checkpoint-trailer.patch` | **a vision conversation had no disk frontier, so an escape re-prefilled the whole prompt.** Nine `!multimodal` guards closed the disk tier to vision because the payload carries image-conditioned KV rows that the token text cannot name — the guard was right; the disk tier was just the only place residency lives. Measured 2026-11-14 15:06 (owner's escape, vision profile): `live kv cache miss … live=242039 prompt=240227 common=240217` then `chat ctx=0..240227` — **99.996 % of the prompt already computed, thrown away**; 51.2 % of the rebuild in 92.7 s, so ~181 s for a 10-token suffix. The 3 h log has exactly 2 `kv cache stored` lines, both from the text conversation. Now the trailer names the images its own range covers — ordered `token_start`, row count, pixel fingerprint, read from the session that produced the rows (`ds4_session_active_image_*`), not from whatever request is in scope — and the loader verifies that list **before** the payload is read into a session. The existing trailer `load` hook fires after the payload is resident and its return value is discarded, so it cannot reject anything: `verify` is new. A mismatch is a miss, never an unlink; a frontier inside an image span is not stored at all. **No header format bump** — the section is appended after the tool map and framed from EOF, so an existing checkpoint keeps its bytes, its tool map keeps its position, "no identity" means "covers no image", and the store is never wiped. Stage 1 opens the ladder (`continued`) store, the store-before-evict and the load; near-tail, prompt-tail and cold stay closed. Test `test_vision_identity_trailer`, mutation-checked four ways: a `verify` that always passes (10 assertions red), a `prepare` that accepts a straddling frontier (2), a `verify` that ignores `token_start` (1), a promised-but-missing identity treated as a miss instead of a reject (5). **Deviation from "local patches touch `ds4_server.c` only", by design:** `ds4_kvstore.h/.c` gain the pre-payload `verify` hook, `verify_wanted`, `extra_ext_flags` and one header bit; `ds4.c`/`ds4.h` gain three read-only accessors over the session's active image set plus one setter used after a verified restore. Rationale: the identity must come from the thing that produced the rows, and the tier must be able to refuse a payload before it becomes state. **Collapsed 2026-11-15 (owner: "why do we need to maintain so many?"):** this was three patches — B15 as shipped, B16 (`0017`, the `covered == count` narrowing a field run forced when a partial-coverage load gave the client a 500 and destroyed a good checkpoint: `kv cache hit text tokens=32768` → `chat ctx=32768..292451:259683` for a 307,893-token prompt, 15,442 tokens of image rows lost), and B17 (`0018`, the revert, because the token-text key made the whole mechanism unreachable while it wrote 20+ GiB per turn, held the store at 233/240 GiB and cut prefill from 884 t/s to 527 t/s). Net effect of the three is exactly this row: the identity format, the pre-payload `verify` hook, the engine accessors and the `canonicalize_tool_checkpoint` span pass, with the tier closed. One patch carries it; the three-patch chain and its full measurements live in `Projects/ds4/progress.md` and the design changelog. Reopening is one patch with the marker-normalized key **and** the tail splice **and** the end-to-end token-count assertion — that is `0017` | ours, no PR |
| **B16 (withdrawn 2026-11-15)** | ~~`patches/0017-kv-vision-load-requires-full-image-coverage.patch`~~ — file deleted, collapsed into B15 | **WITHDRAWN: its three lines are inside B15's single patch now. Kept as the record of why the load gate existed. Original row:** **B15 let a vision request load a checkpoint that covered only some of its images, and the rebuilt tail was short by every image it skipped.** The disk tier rebuilds the tail by tokenizing the text after the cached prefix; image markers in that tail tokenize to a few tokens, not the thousand placeholder rows the prompt holds. Measured 2026-11-14 19:28:13 (owner's escape, 18 images, prompt 307,893): `kv cache hit text tokens=32768 text=113917 key=token-text load=286.2 ms` → `chat ctx=32768..292451:259683` → the engine refused the sync (`image span does not cover image placeholder tokens`) → **the client got a 500** → `kv cache discarded reason=prompt-sync-failed`, so the failure also destroyed a good checkpoint. Now the verify hook requires `covered == count`: a vision checkpoint serves only a request whose every image sits inside its frontier, which is exactly the case where the rebuilt tail holds no image markers. A request that appends an image becomes a miss — the slow turn B15 replaced, not a broken one; the win for that shape needs the live tier's marker-splice helper in this path (stage 2). **The hook also closes a hole that predates B15:** `canonicalize_tool_checkpoint` called the disk load without any image identity, so a multimodal tool turn could already load a text checkpoint into that same corruption; it now passes the request's spans and gets a clean miss. Test: the uncovered-image case in `test_vision_identity_trailer`, mutation-checked (deleting the coverage rule turns the suite red) | ours, no PR |
| **B17 (withdrawn 2026-11-15)** | ~~`patches/0018-kv-reclose-vision-disk-tier-until-key-and-tail-are-vision-aware.patch`~~ — file deleted, collapsed into B15 | **WITHDRAWN: the four closes it made are B15's shape now. Kept as the record of why the tier was closed, and of the reopening rule `0017` pays. Original row:** **B15's mechanism could not be found by the requests it was written for, so it was pure cost.** The disk key is a decode of the stored token ids (`ds4_kvstore_render_tokens_text` → per-token `ds4_token_text`); an image placeholder token decodes to its own text, not to the client's marker with its request-local nonce, so **no checkpoint that spans an image can ever byte-match a later request**. The ladder therefore wrote files the lookup could only reach down to the first image — and B16 then rejected those on coverage. Measured 2026-11-14 19:55–19:56 (owner's escape, 18 images): the turn stored a 9.5 GiB frontier at 19:55, the resume 4 s later selected only the 32,768-token file, logged `identity miss`, and rebuilt **all 307,893 tokens**; that turn had written 20+ GiB, the store stood at **233 of 240 GiB** evicting the text profile's usable checkpoints, and the prefill rate fell from **884 t/s to 527 t/s**. Net effect of B15+B16 on this workload: no win and real harm, so the four sites B15 opened are closed again. **Kept deliberately:** the trailer identity format, the pre-payload `verify` hook, the engine image-identity accessors, and `canonicalize_tool_checkpoint` passing the request's spans — that one closes a hole predating B15. Reopening needs a marker-normalized key (the `visible_prompt_key` \036 masking is the existing precedent) **and** the tail splice in one patch, with an end-to-end test asserting the rebuilt prompt's token count equals the request's — the assertion whose absence let B15 ship | ours, no PR |
| B18 | `patches/0017-kv-vision-marker-normalized-key-and-tail-splice.patch` | **the fix the owner asked for: a vision conversation now gets a disk frontier, and an escape stops costing the whole prompt.** B15's rule ("a checkpoint may serve only a request whose images all sit inside its frontier") was correct for the mechanism it guarded and it made the win unreachable, because two things were missing together, not one. **(1) The key:** a multimodal request now stores and looks itself up by its prompt text with every image marker masked to `\036` (`visible_prompt_key`, the normalization the live tiers already used since `81a7658`), because a marker carries a request-local nonce — one turn's raw text is never a byte prefix of the next, and a token decode is not the marker either. Normalization preserves byte offsets, so the loader's suffix offset stays valid in raw space. **(2) The tail:** `ds4_kvstore_build_prompt_with_vision_suffix` rebuilds the prompt from the payload's exact tokens plus the request's suffix text with each image after the frontier spliced from the request's own prompt rows — the disk analogue of `build_live_prompt_suffix` — and the spliced images' positions are written back into the request's spans, so the sync sees where the rebuild actually put them. A marker run that is not the mask, or a block that would read past the request's prompt, is a **refused load** (never an unlink): the file stays right for the request that wrote it. `verify` now accepts a request that appends images, provided each appended image starts at or after the frontier the loader continues from. **Sites opened:** the completed-prompt frontier store (`kv_cache_maybe_store_prompt_tail`) and the disk load. **Closed on purpose:** the `continued` ladder, the cold store and the token-text `evict`/`shutdown` branches — the ladder was the 20 GiB/turn storm and its key can never match a marker. **Budget decision:** the vision frontier is a `near-tail` checkpoint, so the existing supplementary pool is the guard — capped at `min(budget/8, 16 GiB × sessions)`, it **refuses** instead of evicting and prunes to 2 files per session, so a vision conversation can no longer evict the text profile's anchors. **Prerequisite in the field:** the pool only admits when the store has free space, and this box stood at 239 of 240 GiB, so the store must be cleared once or every vision write is refused. **The assertion 0016 lacked**, now in `tests/test_kvstore_near_tail.c` (mock engine, one token per byte, so the lengths are arithmetic): a spliced load rebuilds `payload + text + rows + 2` tokens and holds the request's real rows at the reported position, the same load without the splice comes out short by the rows (that is the 2026-11-14 19:28:13 defect measured as a number), a fake marker run is refused, and a block running past the prompt is refused — each of the three mutations turns the suite red. `test_vision_identity_trailer` gains the appended-image pair (accepted at/after the frontier, rejected before it). **Deviation:** `ds4_kvstore.h/.c` gain the tail types, the `vision_tail` hook field and the builder; `ds4_server.c` does the normalization and the position write-back. `canonicalize_tool_checkpoint` deliberately passes no tail — its key is a canonical re-render, so a multimodal tool turn stays the plain miss it was | ours, no PR |
| **B19** | `patches/0018-server-prefill-preempts-decode.patch` | **prompt processing pre-empts generation (owner ruling, 2026-11-24): a step is either a prefill chunk or a decode batch, never both, and a queued prefill wins the executor over every pending decode token.** The old policy was the opposite — "long prefills yield to active decoders in bounded intervals, normally 128 tokens" — and the field receipt says it lost both ways. Same box, `--batched-session 2`, 2026-11-24 11:37–11:41: a 215,073-token rebuild ran in 128-token chunks at 90–210 t/s while a peer decoded, and the peer still fell from ~25 t/s to `chunk=13.57 t/s`, with its own 1,116-token prefill costing **108.161 s** (`avg=10.32 t/s`) mostly waiting for a turn. When the peer's decode ended, `generation_active` went false, the chunk became 2048, and the same rebuild ran at `chunk=968.62 t/s`. So the small chunk bought prompt throughput down by ~5× and did not protect decode. **Mechanism, two halves:** execution was already exclusive (`inference_mu` plus `model_busy`), so this was never simultaneity — it was priority and chunk size. (1) `server_prefill_enter` waited on `decode_pending > 0`, a *queued* token rather than an in-flight batch, so a steady stream of decode requests starved prompt work; (2) `decode_worker_main` gated only on `model_busy`, so a queued prefill could not stop the next decode batch from starting. Now both sit on one state read two ways: `server_decode_step_allowed_locked` (free executor **and** no prefill queued) and `server_prefill_step_allowed_locked` (free executor **and** my round-robin turn). A queued token stays withdrawable while it waits — `server_cancel_pending_decode_locked` touches no backend state — so removing the prefill's wait on it cannot strand it, and the two predicates share `model_busy` and the prefill queue, so they cannot deadlock. Decode still runs *between* two chunks of the same prefill, which bounds how long a generation can be held. **Chunk:** `--mixed-prefill-quantum` now defaults to `0` = "do not shrink"; a positive value is the operator's deliberate trade of prompt throughput for a sooner decode step. The GLM-5.3 1024 floor and the round-robin between two prefills are untouched. Tests: new `test_prefill_preempts_decode` (mutation-checked both ways: drop the prefill-queue clause from the decode gate → 1 assertion red; restore the queued-decode wait in the prefill gate → 3 red) and `test_mixed_prefill_quantum_option` rewritten for the new default (0 keeps the wide chunk while a peer generates, the engine cap applies in both states, an explicit cap binds only while generating). `ds4_test --server` → `ds4 tests: ok`. **Deviation from "local patches touch `ds4_server.c` only": one line in `ds4_help.c`, so `--help` stops advertising the old 128 default.** **Pass conditions for the live smoke (step 4, owed):** startup prints `mixed_prefill_quantum=2048` — the effective value, `128` on the old binary; during a long rebuild on one slot the log shows `prefill chunk 2048/…` and **no** `chunk 128/…` lines, and the peer's `decoding` lines pause rather than interleave; the peer resumes at its single-session rate (~24–26 t/s) at the next chunk boundary and never waits longer than one chunk | ours, no PR |

- **Tracker for group A:** upstream issue #1201. Its merge order is
  `1175 → 1169 → 1206 → 1200`, with "#1206 must merge after #1169" (it relies on
  #1169's EOS commitment). A6 and A7 join that workstream from outside the
  tracker; A8 is independent (image decode) and applies last. `build.sh` applies
  `1175 → 1169 → 1206 → 1200 → 1212 → 1216 → 1221 → 1197`.
- **Rejected from the 2026-10-16 survey, with the reason** (so the next survey
  does not re-open them without new evidence):
  - **#1170** — checkpoint selection + eviction, 25 KB. Overlaps A7 on the lookup
    we needed, conflicts with B2 at the disk guard (2 regions measured), and
    interacts with #1200. Revisit only if A7 proves insufficient.
    **Re-surveyed 2026-10-29 against the tree with B6–B8: 4 conflict regions**
    (`ds4_kvstore.c` store-admission + the text-prefix lookup, `ds4_server.c`
    `kv_cache_store_current` signature + the evict call site). Its lookup helper
    is a weaker copy of A7's, so that region resolves by deleting theirs. **Scope
    check first, though:** `protect_text` is *this request's* prompt, so #1170
    fixes the self-evict case its own message names ("the outgoing store evicted
    the snapshot the same request loads right after") and does **not** protect a
    *peer's* checkpoint from a store on another slot — which is the 2026-10-29
    19:13:55 loss. B8 plus the 240 GiB budget address that by sizing; #1170 stays
    out until a cross-session protection is added to it.

## Known conflicts inside our own contract

These are not our bugs. They are upstream PRs we carry that changed the same rule
from opposite directions, and upstream never ran them together because #1201's
tracker order does not contain them both.

- **A2 (#1169) × A6 (#1212) — `test-qwen-tool-disk-key` fails 8 of 9 rows.**
  Measured 2026-10-31 on `c97964b` and on `ee7e840` alike, with only A2 and A6
  applied, so no B patch is involved. The stored payload is exactly **10 bytes
  longer** than the fixture expects, every extra byte at the tail, and the visible-key
  flag condition holds in all 9 rows. A2's stated purpose is changing precisely that
  committed-suffix rule for Qwen tool-visible keys, so A6's fixture predates it.
  **Do not "fix" this by editing the fixture.** The expectation belongs to #1212's
  author, and a green test I wrote would hide a real disagreement between two
  upstream authors. Re-check when either PR merges upstream, or when #1212's author
  rebases onto #1169.
- **A4 (#1200) × A6 (#1212) — link error, fixed by B9.** A4 added a
  `ds4_session_payload_bytes` call on the store's near-tail admission path; A6's
  standalone test links the store without `ds4.c`. B9 is the same stub A4 ships in
  its own test.
  - **#1168** — speculative-drafting backoff, 70 KB, 2 conflict regions. We run
    `--mtp`; judge it on our own `--mtp-timing` data first.
  - **#1205** — the GLM-5.3-only variant of our option C. Not applicable to Qwen.
  - **#1153** — `--image-prefix-snapshot` for issue #1007. Conflicts with B2; B4
    already fixes the truncated-vision-block cause.
- **Archive:** `patches/archive/0005-…superseded-by-pr-1206.patch` is our FIX-1
  (carry final-answer reasoning in the visible suffix). #1206 fixes the same bug
  with a two-key design that also covers clients that omit the reasoning, and it
  edits the same functions, the same test and the same registration line, so
  both cannot apply. Our version is kept for the record and is **not** applied.
- **Still open upstream, not in the build:** #1170 (keep the disk KV checkpoint
  the next request loads — same target as our follow-up (b), conflicts with B2),
  #1153 (`--image-prefix-snapshot`, issue #1007), #1205 (snapshot rewind,
  GLM-5.3 only).

## Where everything lives

| Artifact | Path | Notes |
|---|---|---|
| Build script | `~/repos/ds4/build.sh` | resolve → patch → build → install → re-sign |
| **Contract commit** | `CONTRACT_REF` in `build.sh` (today **`b3f5018`**, moved 2026-11-10 from `c97964b` per §C: pr1175 adapted to the #1245 `SERVER_MAX_IMAGES` rename, pr1200 `.gitignore` union, pr1169/pr1212 3-way context merges; all 21 re-applied clean, §Verification 1–3 passed) | the upstream commit the whole patch set is verified on; it is the **default**, so a plain `./build.sh` never builds an unverified tree |
| Upstream PR patches | `patches/upstream/` | stored verbatim diffs, pinned by the SHAs above |
| Our patches | `patches/` | `0001`…`0004`, `0006`…`0018` (0005 is archived), numbered; next is `0019` |
| Archived patch | `patches/archive/` | kept for the record, never applied |
| Upstream repo | `origin` = `git@github.com:antirez/ds4` (SSH — unusable on this box, see §Fetch) | upstream branch is **`main`**, not `master` |
| Fix branch | `fix/responses-replay-status-tolerance` (**local only** — removed from the fork 2026-11-11: its commit metadata carried machine-default emails and the fork is public) | carries `build.sh` + `patches/` + docs; the local branch is the record/fallback; never push it again |
| **Live contract branch** | `contract/b3f5018` (fork `isgallagher/ds4`) | the same artifacts re-landed fresh on `b3f5018` (a fresh branch, never a history replay); the running server builds from this branch |
| PR branch (clean artifact) | `pr/responses-fork-heal` (fork `isgallagher/ds4`, PR #1194) | single code commit only. **Never** put `build.sh`/`patches/`/private docs on it |
| Running server | `pgrep -f "ds4-server --ctx"` | one server at a time on this box |
| Debug launcher | `~/.ds4/fc-debug/start-probe-trace.sh` | probe env + `--trace`, capture home `~/.ds4/fc-debug/` |

## The safety behaviors (what build.sh does on purpose)

1. **A patch that won't apply → hard stop, before compiling.** `apply()` tries a
   plain `git apply`, then a 3-way (`-3`) apply, and stops with the patch name
   and the error if both fail. Never let a half-applied tree build. On the
   contract commit this means the patch set itself moved (a rebase of the patch
   is due, §Rebasing); anywhere else it means you are off-contract (§C).
2. **Conflict markers are a build error.** A 3-way merge can "succeed" while
   leaving `<<<<<<<` markers in the file. After every patch `apply()` greps the
   whole tree for markers and stops if any survive, so you get "CONFLICT MARKERS
   LEFT BY <patch>" instead of a confusing syntax error three minutes later.
3. **Each patch is committed in the worktree before the next is applied.** The
   3-way fallback needs an index matching HEAD, and the per-step commit makes
   "which patch broke this tree" answerable.
4. **Order matters and is fixed.** Group A in tracker order, then group B in
   number order. Keep the numbering: the next free local patch number is
   `0019` (0005 is archived), and its `apply` line goes after the existing ones.
5. **The working tree is never a build input.** The build happens in a throwaway
   `git worktree` at the fetched upstream commit; only `./ds4-server` comes back
   out, and `codesign --force -s -` runs on it (see §Swapping the live server).
6. **`CONTRACT_REF` is the default upstream, and it is a pin, not a branch.** A
   plain `./build.sh` resolves it from the local object store and touches no
   network. `REF=<sha> ./build.sh` builds another commit and prints a notice when
   it is not the contract commit; `REF=main ./build.sh` fetches current upstream
   and is the way to *start* a re-verification (safety behavior 1 will stop it).
   Reproducing an old build is the same trick: `REF=fc80bd6 ./build.sh` rebuilds
   the 2026-10-16 tree. This is what separates "upstream moved" from "my patch
   changed" — on 2026-11-01 `main` reached `b4e3faf`, `pr1175` stopped applying at
   `ds4_server.c:9937`, and the pinned build kept working.

## Why A3 is not the raw PR

The raw #1206 diff conflicts with #1175 and leaves one call site short an
argument. `patches/upstream/pr1206-integrated.patch` is #1206 with the three
resolutions folded in, so the build never sees a conflict:

- `live_tool_state_clear_locked()` — both PRs add a field to clear
  (`parent_key`/`parent_images` from #1175, `visible_reasoning_text`/`_len` from
  #1206). Resolution: union, both.
- `tests/test_server_vision_live_state.py` — each PR adds a section function at
  the same point, and both edit the `--section` argparse. Resolution: keep both
  functions, one `--section` choices list with all four values, keep
  `--reasoning-replay`, union the dispatch chain.
- `publish_qwen_tool_frontier()` (from #1175) calls `responses_live_remember()`,
  whose signature #1206 grows by `visible_reasoning_text`. Resolution: pass
  `NULL` — that helper publishes a tool-call frontier, not a final-answer one.

This matches the resolution another user published on #1206/#1200 on 2026-10-16.
If #1175 or #1206 changes upstream, regenerate A3 (§One fix changes).

## The four change scenarios

### A. One fix changes → regenerate its patch

A patch is a diff. Cut it from the commits that define the fix, prove it is the
same change you already tested, then run §Verification.

```sh
cd ~/repos/ds4
# a local patch, from its commits against the upstream base it was cut from:
git diff <base> <tree> -- ds4_server.c > /tmp/000X.patch
diff /tmp/000X.patch patches/000X-….patch          # sanity: expect identical
# an upstream PR patch, from its ref (fetched per §Re-fetching a PR ref):
git diff "$(git merge-base fc80bd6 refs/pr/1221)..refs/pr/1221" > /tmp/pr1221.patch
```

Rules of thumb:
- Keep each patch **one concern**. Local patches touch `ds4_server.c` only.
- A3 is the exception by design: it is a PR plus its integration resolutions.
- The committed patch files and the running branch are cross-checks on each
  other; §Verification step 2 is that check.

### B. An upstream PR lands in `main` → drop its patch

1. Remove the matching `apply patches/upstream/prNNNN.patch` line from `build.sh`
   (move the file to `patches/archive/` for the record).
2. Re-run `./build.sh`. If you forget, safety behavior 1 catches it — a patch
   already upstream fails to apply, so a green build is the confirmation.
3. If a *dependent* patch was resolved against it (A3 against #1175), re-check
   the resolutions: the conflict may disappear or move.
4. Update the table above.

### C. Upstream `main` moved and a patch no longer applies

This is what `REF=main ./build.sh` hits, and it is why the default is a pin: the
build stops and names the failing patch while the contract commit still builds
fine. Measured 2026-11-01: `main` = `b4e3faf`, 4 commits past the contract, 47
changed lines in `ds4_server.c`, and `pr1175` conflicts in exactly 1 hunk.

Two moves:
- **Keep building:** `./build.sh`. The default *is* the last verified commit, so
  nothing is owed to keep working. The cost is that upstream features stay out.
- **Move the contract (rebase the patches):**
  1. `git worktree add /tmp/ds4-rebase <new-main-sha>` (detached).
  2. Apply the earlier patches in order, then `git apply --check` the failing
     one. The error and hunk context show what upstream changed around the fix.
  3. Edit the patch (or regenerate it against the new base) so it applies.
  4. `git worktree remove --force /tmp/ds4-rebase`; run the full verification
     (§Verification after any build change) **on the new commit**, not on the old one.
  5. Change `CONTRACT_REF` in `build.sh` in the same commit as the rebased
     patches, so the pin and the verification can never disagree.

  The fix's *logic* does not change during a rebase — only its context lines. If
  a hunk needs a logic change, stop: that is a new interaction, not a rebase.

### D. A cluster PR gets a new head → re-fetch and re-integrate

1. Re-fetch the ref (§Re-fetching a PR ref), regenerate that patch file, run
   `./build.sh`.
2. If it now conflicts with a sibling PR, fold the resolution into the
   `-integrated` file rather than adding a build-time merge.
3. Re-run §Verification — A3's resolutions are the fragile part of this build.

## Re-fetching a PR ref

```sh
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  git -c credential.helper= fetch --depth=50 https://github.com/antirez/ds4.git \
  "+refs/pull/1221/head:refs/pr/1221"
git diff "$(git merge-base fc80bd6 refs/pr/1221)..refs/pr/1221" > patches/upstream/pr1221.patch
```

Local refs exist for `1153 1169 1170 1175 1200 1205 1206 1212 1216 1221`.

## Verification after any build change

Run in this order; a change is "done" when all four pass:

1. `./build.sh` → exit 0, and the last line names the upstream sha and the patch
   counts. Every apply line reads `applied (clean)` except the ones that
   legitimately need `-3`.
2. **Byte-identity invariant.** Rebuild the patch sequence in a throwaway
   worktree and compare against the tree you actually tested:
   ```sh
   WT=$(mktemp -d /tmp/ds4-eqv-XXXXXX)
   git worktree add --detach "$WT" <upstream-sha-used>
   for p in <the nine patches, in build.sh order>; do
       git -C "$WT" apply "$PWD/$p" 2>/dev/null || git -C "$WT" apply -3 "$PWD/$p" || { echo "STOP $p"; break; }
       git -C "$WT" add -A; git -C "$WT" -c user.email=v@v -c user.name=v commit -qm v
   done
   diff -q "$WT/ds4_server.c" <tested-tree>/ds4_server.c && echo IDENTICAL
   git worktree remove --force "$WT"
   ```
   This catches a stale patch file: the built tree must equal the tree the tests
   ran on, or the test result describes a different build.
3. `make -C <a clean worktree or the repo> CC=/usr/bin/clang ds4_test && ./ds4_test --server`
   → `ds4 tests: ok`. Expected noise: `thinking not closed, ignoring incomplete
   Qwen tool calls in reasoning` (a synthetic 1-token case) and two
   `-Wpointer-sign` warnings at the B3 probe's base64 call sites.

   **Also run both model-free targets our patches add** — `ds4_test --server` does
   not cover them, and that gap hid a broken link for the whole life of A6:
   ```sh
   make CC=/usr/bin/clang test-kvstore-near-tail     # A4's store regression
   make CC=/usr/bin/clang test-qwen-tool-disk-key    # A6's key regression
   ```
   `test-kvstore-near-tail` → `PASS`. **`test-qwen-tool-disk-key` is knowingly red:
   it fails 8 of 9 rows** (`FAIL (8 failures)`), and that is the expected state of
   this contract — see §Known conflicts. Anything else, including a link error or a
   different count, is a new fact and needs looking at.
4. Live smoke on the port: a `/v1/responses` tool round trip completes with no
   400 (B1), and the log shows normal `responses live continuation` hits. The
   fork-heal (B2) only shows up under a forked-history repro, and the reuse
   tiers from group A show up in `~/.ds4/fc-debug/` trace captures.

### Verification record

Re-verified 2026-10-31 against upstream **`c97964b`** (13 commits past `ee7e840`, the
base of the binary running now) after A6 was regenerated and B9 added. Every patch
applies: A1 and A2 with `-3` as documented, A6 and all nine group-B patches **clean**.
`ds4-server` builds with zero errors and the same two `-Wpointer-sign` warnings;
`ds4_test --server` → `ds4 tests: ok`; `test-kvstore-near-tail` → `PASS`;
`test-qwen-tool-disk-key` links and reports the documented `FAIL (8 failures)`
(§Known conflicts).

**Step 4 passed 2026-10-31 15:36–16:02** on `start-qwen38-batched-vision.sh`
(ctx 262144, `--batched-session 2`, mmproj, 240 GiB budget, disk tier emptied
first): `resident_sessions=2`, no MTP-disabled line, RSS 92.4 GiB against the
116 GiB wired limit, cold turns 269.506 s / 125.595 s, **every subsequent turn
0.245–4.224 s**, 11 checkpoint stores including both conversations' frontiers,
`kv cache discarded` **0**, `discarding and healing` once and then silent, and the
`common=6897` harness-prefix miss appearing once rather than every turn.
Full table and caveats: `docs/RESPONSES_CACHE_MISS.md` §9. The disk-**hit** path is
still untested in the field — the store started empty.

A reverse-apply check (`git apply -R --check` on clean `c97964b`) reads `absent` for
every one of the 17 patches: **none of what we carry has been merged upstream**, so
none can be dropped. That check is the cheap way to answer "do we still need these" —
recorded here so the next survey runs it instead of reading PR pages.

What upstream added since `fc80bd6`, that touches us: Qwen PLE prefetch (#1154) and
Q4_K raw-load register reuse (`docs/QWEN38_Q4_REGISTER_REUSE.md`, +2.376% text and
+2.274% C-source prefill on M5 Max 128 GiB at 8192-token chunks, decode unchanged);
`a8ce74a` renders blank reasoning as absent, which stops one stray body token from
breaking every later prefix match; `2768d0e` fixes a progressive-JPEG out-of-bounds
that upstream states is reachable from request images when `--vision` is enabled.
Consequence: **numbers captured on the `fc80bd6` binary are not a baseline** for a
current one.

**B10 + B11 added 2026-11-01** (escape-interrupt full re-prefill, owner-confirmed
incident 2026-10-31 19:48 — full diagnosis in `docs/RESPONSES_CACHE_MISS.md` §10).
Both apply **clean** on `c97964b` after the 17-patch sequence; `ds4-server` builds
with zero errors and the same two `-Wpointer-sign` warnings; `ds4_test --server` →
`server: OK`, `ds4 tests: ok` (new: probe case 8, `test_responses_cancel_release_live`);
fresh-tree byte-identity vs the tested tree holds. **Step 4 is owed**: escape
mid-thinking in one batched client, send the next message, expect
`generation cancelled mid-turn … visible-state=remembered` then a short prefill with
no `forked-payload` discard; and a compaction turn to exercise the B11 candidate
retry. **Superseded for B10 by B12 (2026-11-01 late): the escape smoke cannot validate
B10, because an interrupted decode returns at an earlier branch. B10's unit tests and its
silent-branch finding stand; its escape claim does not.**

**B12 added 2026-11-01 late** (the branch the escape takes — inventory in
`docs/RESPONSES_CACHE_MISS.md` §11). Source-mapped with no restart and no log: a
read-only worktree at `c97964b` with the then-19-patch sequence applied, one pass to
enumerate every live-state clear site with its guard and whether it emits a
`server_log` line. B12 applies **clean** after the 19; `ds4-server` and `ds4_test` build
with zero errors and the same four `-Wpointer-sign` warnings (two sites, each seen in
both targets); `ds4_test --server` → `server: OK`, `ds4 tests: ok`; fresh-tree
byte-identity vs the tested tree holds; reverse-apply reads present on the built tree.
The new test is **mutation-checked**: moving one byte of the surface-length assertion
turns the suite red, which is the proof that the test executes.
**Step 4 owed for B12:** escape mid-thinking in one batched client, send the next
message, expect `generation cancelled mid-turn … visible-state=remembered-partial` then
a near-tail prefill, no `forked-payload`, and no eviction of the frontier slot. Expect
`visible-state=cleared` when the partial carried both reasoning and content, or reached
a tool call — that is the designed safe miss, not a regression.

**B13 added 2026-11-01** (owner's escape at 10:16; evidence in
`docs/RESPONSES_CACHE_MISS.md` §12). Applies **clean** after the 20-patch sequence on
`c97964b`; `ds4-server` and `ds4_test` build with zero errors and the same four
`-Wpointer-sign` warnings; `ds4_test --server` → `server: OK`, `ds4 tests: ok`; fresh-tree
byte-identity vs the tested tree holds; reverse-apply reads present. No new unit test: the
change is a branch on an existing predicate, and the observable is the log line
`kv cache entry kept reason=cancelled-*` in place of `kv cache discarded`. **Step 4 owed for
B13:** interrupt a turn while a long prefill runs, and confirm the payload survives
(`entry kept`, not `discarded`) and the following request still hits that token count.

**B14 added 2026-11-14** (owner's "the images keep being reprocessed every time"; evidence
in the 3 h log of the `start-qwen38-longctx-vision.sh` session, 06:15-09:04). Applies
**clean** after the 21-patch sequence on `b3f5018`. §Verification 1-3: `./build.sh` exit 0,
**22 of 22 `applied (clean)`** (this run needed no `-3`), last line
`b3f5018 + 8 upstream PR patches + 14 local patches`, `codesign -v` clean; fresh-tree
byte-identity holds for `ds4_server.c` **and** `ds4_help.c` vs the tested tree;
`ds4_test --server` → `server: OK`, `ds4 tests: ok` (only the documented
`thinking not closed` line); `test-kvstore-near-tail` → `PASS`;
`test-qwen-tool-disk-key` → the documented `FAIL (8 failures)`.
**Two new tests, both mutation-checked:** lowering `SERVER_IMAGE_CACHE_DEFAULT_MB` back to
128 fails 2 assertions in `test_vision_cache_mb_option`; a `put` that ignores its budget
fails `cache.bytes <= tight` in `test_server_image_embedding_cache_thrash`.
**Test defect found and fixed while adding B14:** `test_server_image_embedding_cache`
built its keys in one byte, so with the cap raised to `SERVER_MAX_IMAGES` (256) key 257
aliased onto key 1 and the eviction assertion would have passed for the wrong reason — the
loop and the lookup now use two key bytes. **Step 4 owed for B14:** start the vision
profile, confirm `vision embedding cache 1024 MiB, 256 entries` at startup, then run the
15-image agent session and confirm the per-turn pattern returns to
`hits = images-1, encodes = 1` instead of `hits = 0, encodes = 15`.

**B15 collapsed and B18 added 2026-11-15.** The collapse is `git diff` of the three
patch commits squashed into one file: a fresh worktree at `b3f5018` + the 23-patch
list applies with **0 failures** and the five touched files are sha256-identical to
the tested tree, so the collapse changes no code. Then §Verification 1–3 on the
24-patch chain: `./build.sh` exit 0, **24 of 24 `applied (clean)`**, last line
`b3f5018 + 8 upstream PR patches + 16 local patches`, `codesign -v` clean, binary
`e2fa07b5…`; fresh-worktree byte-identity holds for `ds4.c`, `ds4.h`,
`ds4_kvstore.c`, `ds4_kvstore.h`, `ds4_server.c` **and** `tests/test_kvstore_near_tail.c`
vs the tested tree; `ds4_test --server` → `server: OK`, `ds4 tests: ok`; `test-kvstore-near-tail`
→ `PASS` (with the new vision-tail section); `test-qwen-tool-disk-key` → the documented
`FAIL (8 failures)`, unchanged count. **Step 4 PASSED for the same-images shape 2026-11-14
22:00** (owner's run, store cleared first, server started 21:47): `21:55:23 kv cache stored
tokens=307893 trimmed=0 reason=near-tail key=responses-prompt size=10136.63 MiB
save=4702.0 ms` → `22:00:43 generation cancelled mid-turn live=318864` → `22:00:56 live kv
cache miss … prompt=307893 common=307893 vision=match reason=token-mismatch` → `22:00:58 kv
cache hit text RESPPROTO tokens=307893 text=956539 key=responses-visible load=1731.0 ms` →
**`chat ctx=307893..307893:0 prompt done 0.000s`**, first 50 tokens 1.41 s later — **zero
tokens prefilled where the same escape cost 307,893 tokens / 583.140 s on 2026-11-14 19:56**,
with 0 `identity miss`, 0 `vision tail refused`, 0 `vision frontier rejected`, 0 `kv cache
discarded`, 0 prefill failures and 0 500s in the 1,126-line run. The store went 239 G/43
files → 96 G/18 files, and the only `continued` ladder stores in the window belong to a text
conversation on the same server, which is the intended split. **Step 4 still owed for B18:
the appended-screenshot resume** — the retry's prompt was byte-exact to the frontier (the
client dropped the escaped partial), so the splice did not run in the field and stands
unit-proven only. Operator note: the owner's own re-run of `./build.sh` produced a different
digest (`dfdea3a3…`) from the same commit, because the link is not reproducible — the commit
and the source byte-identity are the contract, never the digest.

**Eight-day re-check 2026-11-22 (same build, `dfdea3a3…` from `05de09a`, server up since 02:33).**
Clean on every safety property: since the fix there is **no** `identity miss`, `vision tail
refused`, `vision frontier rejected`, `kv cache discarded`, prefill failure or 500 anywhere in
the 12.7 MB vision log — the only ones present are the four misses and the one discard from
19:22–19:56 on 2026-11-14, before it. **New finding, not a defect in 0017:** the store is back
at 238 G/34 files and `supplementary admission has no room` has been logged **43 times** (most
recently 2026-11-22 22:47), with **no near-tail store since 2026-11-18 16:55** — so the vision
frontier is currently not being written at all. Cause and the three options are documented in
`docs/RESPONSES_CACHE_MISS.md` §13: `kv_cache_tail_admit()` needs whole-store free space and
never evicts, while the main pool runs the store to its 240 GiB budget. The cheapest immediate
answer is `--kv-disk-space-mb` (240 GiB today, 387 GiB free on the volume). **The appended-
screenshot resume is still owed** — the splice has never run in the field.
the bug cost.

**Re-verified 2026-11-24 after B19 was added** (`0018`, scheduler only, no format
or store change). Step 1: `./build.sh` → exit 0, `b3f5018` + 8 upstream + 17
local, every apply `applied (clean)`. Step 2: byte-identity — a throwaway
worktree carrying all 25 patches matches the tested tree in **both** files the
patch touches (`ds4_server.c`, `ds4_help.c`): `IDENTICAL`. Step 3: `ds4_test
--server` → `ds4 tests: ok`; `test-kvstore-near-tail` → `PASS`. **New fact, not
caused by B19:** `test-qwen-tool-disk-key` no longer *compiles* —
`tests/test_qwen_tool_disk_key.c:210` and `:231` call `kv_cache_store_current`
with 3 arguments and the signature took a 4th with `0016`. The record above
("it links and reports the documented `FAIL (8 failures)`") is therefore stale as
of `05de09a` (2026-11-14/15): the target was not run when 0016/0017 landed. Two
call sites, one fix; it needs its own patch and its own four-step. **Step 4 for
B19 is owed:** the live smoke needs the swap, and the swap costs the owner's two
live sessions. Pass conditions for that smoke are in the B19 row and in
`Projects/ds4/build.md`.

## Swapping the live server onto a fresh build

**Restarting ends the owner's live session's live KV. Never restart without the
owner's go** (standing go exists for the capture/work server, not for a live
owner session). Their session re-prefills from disk or from zero — warn them
which.

```sh
cd ~/repos/ds4 && ./build.sh          # installs + re-signs ./ds4-server
codesign -v ./ds4-server              # must be silent
pgrep -f "ds4-server --ctx"           # the running one, untouched by the install
```

`build.sh` runs `codesign --force -s - ./ds4-server` after the copy. That is not
cosmetic: a copy-modified binary is SIGKILLed at startup by macOS code signing
("Invalid Page" inside dyld). If the kill returns *after* a re-sign, treat it as
a machine-level issue (AMFI events, disk health) — an owner call.

Debug run (probe + trace, capture home `~/.ds4/fc-debug/`):
`~/.ds4/fc-debug/start-probe-trace.sh`. Its header carries the `nohup` form that
redirects stdout into a log file; without it the miss lines and the
`CACHEMISS_DEBUG` windows go only to the terminal and are lost on scrollback.

## Fetch: why the env gymnastics are load-bearing

On **this machine** `git fetch origin` cannot work: `origin` is SSH, SSH to
github.com times out (port 443 blocked), and a **global**
`url.git@github.com:.insteadOf https://github.com/` rewrites even explicit
HTTPS fetches back to SSH. `build.sh` therefore fetches anonymously over HTTPS
(repo is public) with the global config bypassed:
`GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -c credential.helper= fetch https://github.com/antirez/ds4.git main`.
On a machine without those quirks the same command still works (public repo, no
credential needed) — don't "clean it up" per-machine without re-reading this
section. Pushing to the fork has the same SSH problem; the working form is
`git -c credential.helper= push https://isgallagher:$(gh auth token)@github.com/isgallagher/ds4.git <branch>`.

## Do-not list

- Don't add `patches/` or `build.sh` to `pr/responses-fork-heal` (the PR artifact
  stays a single code commit).
- Don't commit `patches/` changes without the §Verification four-step.
- Don't apply the raw #1206 diff. Use `pr1206-integrated.patch`; the raw one
  conflicts with #1175 and breaks one call site's arity.
- Don't re-derive a fix by copying files between the PR branch and the fix
  branch — that is how the 400 fix was silently dropped once (2026-10-07,
  recorded in `Projects/ds4/progress.md`). Regenerate patches from commits;
  verify with `diff -q`.
- Don't share one `--kv-disk-dir` between profiles with different rope scaling
  (`DS4_QWEN4_YARN_FACTOR`). The checkpoint header has no rope field and the
  `ctx_size` filter is one-directional, so a 393k session can silently load
  262k-era KV computed in a different rotary frame. Rationale and layout:
  `docs/KV_PROFILE_ISOLATION.md`.
- Don't assume the fix branch's `ds4_server.c` is what builds. It is based on
  `0aaea5a` and is a carrier for `build.sh`/`patches/`/docs; the binary is
  upstream-tip + patches. The §Verification step 2 comparison is against the
  tested tree, not against the branch file.
