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
| A4 | `patches/upstream/pr1200.patch` | save eligible completed text-only Qwen Responses prompts as a `near-tail` checkpoint before generation. **Its eviction priority and its admission rule are overridden by B8 (2026-11-25): the `0.0` score for `near-tail`, the ×2 anchor score, the 6 h hit decay and the whole-store refusal are gone. Read this row for the tier, not for the policy.** | PR #1200 @ `d18057e`, open |
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
| B8 | `patches/0009-kv-tail-pool-standing-in-the-store.patch` | **two things about the supplementary (`near-tail`) pool: how big it is, and what the store is allowed to do to it.** **(1) Size (as before):** per resident session — cap 16 GiB → 16 GiB × sessions, entry limit 2 → 2 × sessions, from `ds4_kvstore.resident_sessions` set to `slot_count`. `0` reads as `1`, so single-session behaviour is unchanged and A4's test passes untouched. **(2) Standing (added 2026-11-25, owner ruling "always delete the oldest" after his own diagnosis "it was working until the kv cache store filled up, then it started fucking up when it started evicting"):** A4's `pr1200` scores every `near-tail` checkpoint at `0.0` (`/* Supplementary snapshots must leave before any ordinary checkpoint. */`), so the frontier left **before** every ordinary file, while `cold`/`evict`/`shutdown` anchors scored **double** and stayed. Measured in the live store the same day: 240 GiB with **380 MiB** free, **28 files / 168.8 GiB never read once and idle > 12 h**, only 5 files ever read, and two `shutdown` anchors from the 24 Nov 13:43 restart (17.5 GiB, 0 hits) still protected. The owner's own log proved the cost: `29c2419a…` (41,234 tokens) served three turns at 12:11:32, 12:12:42 and 12:14:32 and was gone 90 minutes later, while the 216k conversation resumed from `196608` every turn and paid **19,284 → 19,684 → 20,031 tokens (31–54 s)** because its frontier write was refused. **Now:** `ds4_kvstore_entry_eviction_score` returns the **last-read second** plus one millisecond per read — exit order is oldest-read first, reads break the tie, and reason class decides nothing; the `0.0` for `near-tail`, the anchor ×2, the 6 h hit decay (`DS4_KVSTORE_HIT_HALF_LIFE_SECONDS`) and the superseded-continued-prefix factor are **removed** (their two static predicates and four constants go with them). At an exact tie the **bigger** file leaves, so one unlink buys the most room and the choice stops depending on `readdir` order. `kv_cache_tail_admit_making_room()` runs that same order once and re-checks when the whole store has no byte free, so a frontier is refused only when nothing unreadable can go; the pool's own `min(budget/8, 16 GiB × sessions)` share and `kv_cache_tail_prune` still bound it, so **the store does not grow past the operator's `--kv-disk-space-mb`**. Verified against the store's own headers on 2026-11-25: oldest-**read**-first puts the 8 next victims at 0 hits and frees **47.3 GiB in one pass**, while oldest-**written**-first (llama.cpp's order, `tools/server/server-slot-sched.cpp:277-283`) would have deleted the 0.31 GiB shared prefix with 14 reads first — that is why "oldest" means last read here. Tests: `tests/test_kvstore_near_tail.c` gains the full-store case (fill until the store is exactly full → the plain admit refuses → the store succeeds → the never-read anchor is gone and the frontier is present) and the ordering case (a tail read now scores above an anchor read a day ago); `ds4_server.c` replaces `test_kv_cache_eviction_score_decays_stale_hits` with `…_orders_by_last_read`, `…_prefers_anchor_reason` with `…_ignores_reason_class` (assertions inverted — the older anchor now leaves), `…_prefers_superseded_continued_prefix` with `…_gives_no_priority_to_superseded_prefix`, `…_keeps_smaller_context_prefix` with `…_breaks_a_tie_by_freeing_the_bigger_file`, and `…_decayed_hits_tie_break_by_age` with `…_older_read_leaves_despite_more_hits`. Mutation-checked: restoring the `0.0` turns the store suite red; deleting the new eviction call turns the full-store assertion red. **Renamed from `0009-kv-tail-pool-sizes-with-resident-sessions.patch`** because the patch now owns the pool's standing, not only its size; `build.sh` and this row moved with it. **Touches 4 files** (`ds4_kvstore.h/.c`, `ds4_server.c`, the test) — the deviation from "local patches touch `ds4_server.c` only" is because the policy lives in the store. **It edits `pr1200`'s code, and does not edit `pr1200`:** upstream stays upstream (§6 of the vault design doc, REQ-8), so the override lives here | ours, no PR |
| B9 | `patches/0010-kvstore-test-stub-payload-bytes.patch` | stub `ds4_session_payload_bytes` in A6's model-free test so it links once A4 is in the tree (A4 made the store call it; the symbol lives in `ds4.c`, which that target does not link). A4 ships the same stub in its own test | ours, no PR |
| B10 | `patches/0011-responses-cancel-remember-visible.patch` | a cancelled Responses turn now **remembers** the visible surface at the current frontier (via the turn-end builder) instead of clearing every live handle, and both cancel branches log. Fixes the escape-and-continue full re-prefill (2026-10-31 19:48: 201,688 tokens / 229 s for a conversation 31 tokens from its frontier) and the two-sessions-old "missing disconnect line" mystery (the branches were silent). No KV rewind — rewind is GLM-only; remembering at the frontier keeps the visible tier's strict `live_tokens == live_pos`. Mismatching clients miss safely, as before the fix. Tests: probe case 8 + `test_responses_cancel_release_live`. **Scope corrected 2026-11-01 by B12: the escape path returns at an earlier branch and never reaches these two, so B10 does not serve the escape case — it serves a cancel that arrives after the decode loop finished. The "missing disconnect line" finding stands (five branches are still silent)** | ours, no PR |
| B11 | `patches/0012-kv-fork-next-shorter-candidate.patch` | a forked visible-keyed disk payload no longer ends the disk tier: the 0007 discard stays (protective), the lookup is retried (the refresh inside rescans the store directory, so the discarded file is never offered again), and the next-shorter candidate gets its own lockstep check — a pre-fork ladder checkpoint is token-exact and loads. Bounds any re-render fork at prompt−frontier (2026-10-31 shape: 229 s → ~154 s). Bounded at 4 attempts; live-smoke-verified, same verification shape as B6 | ours, no PR |
| B12 | `patches/0013-responses-cancel-remember-partial-visible.patch` | **the branch the escape actually takes.** `generate_job_inner` has seven `request_live_state_clear()` sites under `job_cancelled`; an interrupted decode returns at the first one after the loop ("cancelled during generation after N tokens"), which B10 left as a silent clear — so B10's log line could never appear for an escape, and the 23:14 / 23:18 recoveries were the disk and memory-token tiers. That branch cannot reuse B10's helper either: the completed-turn builder closes the surface with the model's end-of-turn marker, and a cancelled turn never commits that token, so the handle would claim one token more than the live KV holds — **wrong reuse, not the safe miss**. This patch remembers a **partial** surface (prompt text + reasoning-so-far, or + content-so-far, no marker appended) so the next request re-tokenizes the boundary and end-of-turn tokens onto the live KV; single-surface partials only, everything else keeps the clear. The parser is asked with the closed-thinking requirement off, because the cancelled turn is unclosed by definition. Test: `test_responses_cancel_release_live_partial`, mutation-checked | ours, no PR |
| B13 | `patches/0014-kv-keep-payload-on-cancelled-prefill.patch` | **a cancelled prefill deleted a good checkpoint.** The prefill failure path unlinked the disk payload it had just loaded; B8 gave the cancel its own reason label, but the unlink stayed. Measured 2026-11-01 10:16: a 65,536-token hit from `66b52486…kv`, the prefill cancelled, then the same file unlinked → the next request resumed at 30,985 and re-prefilled **112,866** tokens (~5 min). Every interrupt made the store permanently worse, which is what an owner experiences as "it got slower after I pressed escape". Now the cancel path keeps the payload and runs the same session and schedule bookkeeping (the mid-sync session is still invalidated), logging `kv cache entry kept reason=cancelled-*`. The `forked-payload` discard stays — that payload really is wrong for the prompt | ours, no PR |
| B14 | `patches/0015-vision-embedding-cache-sized-from-flag.patch` | **the vision embedding cache could not hold the conversation, so it re-encoded every image on every turn.** B5 made the key the pixel fingerprint and dropped the client bytes from the accounting, which left `SERVER_IMAGE_CACHE_BYTES` (128 MiB, compile-time) holding **13 images of 1000 tokens** at the 2560-wide fp32 row width (10,240,000 B each). A session that reaches 15 screenshots cannot fit its own working set, and because every request replays every image in history order the LRU victim is always the next image that same request asks for, so one over-capacity step is a **permanent full-set re-encode**, not a one-image degradation. Measured 2026-11-14 (one agent session, 3 h log): 14 hits + 1 encode per turn while the cache climbed to 13,092 of the 13,107 available token-rows, then **0 hits and 15 encodes per turn** (79 s and 83 s of encoder time for requests whose model work was 1.5 s prefill + 22 s decode, with the KV hitting every time: `cached=228077 prompt=228332`). Now: entry cap `32 -> SERVER_MAX_IMAGES` (256, so the entry limit can never bind before the byte limit), and the budget is `--vision-cache-mb N` (default **1024** = ~100 images; `0` disables). Startup logs `vision embedding cache %zu MiB, %d entries`. Tests: `test_server_image_embedding_cache_thrash` (over-budget => every round re-encodes every image, forever; fits-budget => encodes stop after round 1) and `test_vision_cache_mb_option` (default parsed as the literal 1024, and the default must hold the 15x1000-token set that failed). Both mutation-checked: lowering the default to 128 fails 2 assertions; a `put` that ignores its budget fails the thrash bound. **Deviation from "local patches touch `ds4_server.c` only": one line in `ds4_help.c`, so the flag appears in `--help`** | ours, no PR |
| B15 | `patches/0016-kv-vision-identity-in-checkpoint-trailer.patch` | **a vision conversation had no disk frontier, so an escape re-prefilled the whole prompt.** Nine `!multimodal` guards closed the disk tier to vision because the payload carries image-conditioned KV rows that the token text cannot name — the guard was right; the disk tier was just the only place residency lives. Measured 2026-11-14 15:06 (owner's escape, vision profile): `live kv cache miss … live=242039 prompt=240227 common=240217` then `chat ctx=0..240227` — **99.996 % of the prompt already computed, thrown away**; 51.2 % of the rebuild in 92.7 s, so ~181 s for a 10-token suffix. The 3 h log has exactly 2 `kv cache stored` lines, both from the text conversation. Now the trailer names the images its own range covers — ordered `token_start`, row count, pixel fingerprint, read from the session that produced the rows (`ds4_session_active_image_*`), not from whatever request is in scope — and the loader verifies that list **before** the payload is read into a session. The existing trailer `load` hook fires after the payload is resident and its return value is discarded, so it cannot reject anything: `verify` is new. A mismatch is a miss, never an unlink; a frontier inside an image span is not stored at all. **No header format bump** — the section is appended after the tool map and framed from EOF, so an existing checkpoint keeps its bytes, its tool map keeps its position, "no identity" means "covers no image", and the store is never wiped. Stage 1 opens the ladder (`continued`) store, the store-before-evict and the load; near-tail, prompt-tail and cold stay closed. Test `test_vision_identity_trailer`, mutation-checked four ways: a `verify` that always passes (10 assertions red), a `prepare` that accepts a straddling frontier (2), a `verify` that ignores `token_start` (1), a promised-but-missing identity treated as a miss instead of a reject (5). **Deviation from "local patches touch `ds4_server.c` only", by design:** `ds4_kvstore.h/.c` gain the pre-payload `verify` hook, `verify_wanted`, `extra_ext_flags` and one header bit; `ds4.c`/`ds4.h` gain three read-only accessors over the session's active image set plus one setter used after a verified restore. Rationale: the identity must come from the thing that produced the rows, and the tier must be able to refuse a payload before it becomes state. **Collapsed 2026-11-15 (owner: "why do we need to maintain so many?"):** this was three patches — B15 as shipped, B16 (`0017`, the `covered == count` narrowing a field run forced when a partial-coverage load gave the client a 500 and destroyed a good checkpoint: `kv cache hit text tokens=32768` → `chat ctx=32768..292451:259683` for a 307,893-token prompt, 15,442 tokens of image rows lost), and B17 (`0018`, the revert, because the token-text key made the whole mechanism unreachable while it wrote 20+ GiB per turn, held the store at 233/240 GiB and cut prefill from 884 t/s to 527 t/s). Net effect of the three is exactly this row: the identity format, the pre-payload `verify` hook, the engine accessors and the `canonicalize_tool_checkpoint` span pass, with the tier closed. One patch carries it; the three-patch chain and its full measurements live in `Projects/ds4/progress.md` and the design changelog. Reopening is one patch with the marker-normalized key **and** the tail splice **and** the end-to-end token-count assertion — that is `0017` | ours, no PR |
| **B16 (withdrawn 2026-11-15)** | ~~`patches/0017-kv-vision-load-requires-full-image-coverage.patch`~~ — file deleted, collapsed into B15 | **WITHDRAWN: its three lines are inside B15's single patch now. Kept as the record of why the load gate existed. Original row:** **B15 let a vision request load a checkpoint that covered only some of its images, and the rebuilt tail was short by every image it skipped.** The disk tier rebuilds the tail by tokenizing the text after the cached prefix; image markers in that tail tokenize to a few tokens, not the thousand placeholder rows the prompt holds. Measured 2026-11-14 19:28:13 (owner's escape, 18 images, prompt 307,893): `kv cache hit text tokens=32768 text=113917 key=token-text load=286.2 ms` → `chat ctx=32768..292451:259683` → the engine refused the sync (`image span does not cover image placeholder tokens`) → **the client got a 500** → `kv cache discarded reason=prompt-sync-failed`, so the failure also destroyed a good checkpoint. Now the verify hook requires `covered == count`: a vision checkpoint serves only a request whose every image sits inside its frontier, which is exactly the case where the rebuilt tail holds no image markers. A request that appends an image becomes a miss — the slow turn B15 replaced, not a broken one; the win for that shape needs the live tier's marker-splice helper in this path (stage 2). **The hook also closes a hole that predates B15:** `canonicalize_tool_checkpoint` called the disk load without any image identity, so a multimodal tool turn could already load a text checkpoint into that same corruption; it now passes the request's spans and gets a clean miss. Test: the uncovered-image case in `test_vision_identity_trailer`, mutation-checked (deleting the coverage rule turns the suite red) | ours, no PR |
| **B17 (withdrawn 2026-11-15)** | ~~`patches/0018-kv-reclose-vision-disk-tier-until-key-and-tail-are-vision-aware.patch`~~ — file deleted, collapsed into B15 | **WITHDRAWN: the four closes it made are B15's shape now. Kept as the record of why the tier was closed, and of the reopening rule `0017` pays. Original row:** **B15's mechanism could not be found by the requests it was written for, so it was pure cost.** The disk key is a decode of the stored token ids (`ds4_kvstore_render_tokens_text` → per-token `ds4_token_text`); an image placeholder token decodes to its own text, not to the client's marker with its request-local nonce, so **no checkpoint that spans an image can ever byte-match a later request**. The ladder therefore wrote files the lookup could only reach down to the first image — and B16 then rejected those on coverage. Measured 2026-11-14 19:55–19:56 (owner's escape, 18 images): the turn stored a 9.5 GiB frontier at 19:55, the resume 4 s later selected only the 32,768-token file, logged `identity miss`, and rebuilt **all 307,893 tokens**; that turn had written 20+ GiB, the store stood at **233 of 240 GiB** evicting the text profile's usable checkpoints, and the prefill rate fell from **884 t/s to 527 t/s**. Net effect of B15+B16 on this workload: no win and real harm, so the four sites B15 opened are closed again. **Kept deliberately:** the trailer identity format, the pre-payload `verify` hook, the engine image-identity accessors, and `canonicalize_tool_checkpoint` passing the request's spans — that one closes a hole predating B15. Reopening needs a marker-normalized key (the `visible_prompt_key` \036 masking is the existing precedent) **and** the tail splice in one patch, with an end-to-end test asserting the rebuilt prompt's token count equals the request's — the assertion whose absence let B15 ship | ours, no PR |
| B18 | `patches/0017-kv-vision-marker-normalized-key-and-tail-splice.patch` | **the fix the owner asked for: a vision conversation now gets a disk frontier, and an escape stops costing the whole prompt.** B15's rule ("a checkpoint may serve only a request whose images all sit inside its frontier") was correct for the mechanism it guarded and it made the win unreachable, because two things were missing together, not one. **(1) The key:** a multimodal request now stores and looks itself up by its prompt text with every image marker masked to `\036` (`visible_prompt_key`, the normalization the live tiers already used since `81a7658`), because a marker carries a request-local nonce — one turn's raw text is never a byte prefix of the next, and a token decode is not the marker either. Normalization preserves byte offsets, so the loader's suffix offset stays valid in raw space. **(2) The tail:** `ds4_kvstore_build_prompt_with_vision_suffix` rebuilds the prompt from the payload's exact tokens plus the request's suffix text with each image after the frontier spliced from the request's own prompt rows — the disk analogue of `build_live_prompt_suffix` — and the spliced images' positions are written back into the request's spans, so the sync sees where the rebuild actually put them. A marker run that is not the mask, or a block that would read past the request's prompt, is a **refused load** (never an unlink): the file stays right for the request that wrote it. `verify` now accepts a request that appends images, provided each appended image starts at or after the frontier the loader continues from. **Sites opened:** the completed-prompt frontier store (`kv_cache_maybe_store_prompt_tail`) and the disk load. **Closed on purpose:** the `continued` ladder, the cold store and the token-text `evict`/`shutdown` branches — the ladder was the 20 GiB/turn storm and its key can never match a marker. **Budget decision:** the vision frontier is a `near-tail` checkpoint, so the existing supplementary pool is the guard — capped at `min(budget/8, 16 GiB × sessions)`, it prunes only near-tail files (to `2 × sessions`), so a vision conversation can no longer evict the text profile's anchors. **Admission, corrected 2026-11-24:** the gate is the *whole-store* test (`required <= budget_bytes − total`), not the pool's own share, and `kv_cache_tail_prune` runs only after a successful store — so a store at budget **refuses** a vision write before its own prune can make room. **Prerequisite in the field:** the store must have free space, and this box stood at 239 of 240 GiB, so it must be cleared (or the budget raised) or every vision write is refused. **The assertion 0016 lacked**, now in `tests/test_kvstore_near_tail.c` (mock engine, one token per byte, so the lengths are arithmetic): a spliced load rebuilds `payload + text + rows + 2` tokens and holds the request's real rows at the reported position, the same load without the splice comes out short by the rows (that is the 2026-11-14 19:28:13 defect measured as a number), a fake marker run is refused, and a block running past the prompt is refused — each of the three mutations turns the suite red. `test_vision_identity_trailer` gains the appended-image pair (accepted at/after the frontier, rejected before it). **Deviation:** `ds4_kvstore.h/.c` gain the tail types, the `vision_tail` hook field and the builder; `ds4_server.c` does the normalization and the position write-back. `canonicalize_tool_checkpoint` deliberately passes no tail — its key is a canonical re-render, so a multimodal tool turn stays the plain miss it was | ours, no PR |
| **B19** | `patches/0018-server-prefill-preempts-decode.patch` | **prompt processing pre-empts generation (owner ruling, 2026-11-24): a step is either a prefill chunk or a decode batch, never both, and a queued prefill wins the executor over every pending decode token.** The old policy was the opposite — "long prefills yield to active decoders in bounded intervals, normally 128 tokens" — and the field receipt says it lost both ways. Same box, `--batched-session 2`, 2026-11-24 11:37–11:41: a 215,073-token rebuild ran in 128-token chunks at 90–210 t/s while a peer decoded, and the peer still fell from ~25 t/s to `chunk=13.57 t/s`, with its own 1,116-token prefill costing **108.161 s** (`avg=10.32 t/s`) mostly waiting for a turn. When the peer's decode ended, `generation_active` went false, the chunk became 2048, and the same rebuild ran at `chunk=968.62 t/s`. So the small chunk bought prompt throughput down by ~5× and did not protect decode. **Mechanism, two halves:** execution was already exclusive (`inference_mu` plus `model_busy`), so this was never simultaneity — it was priority and chunk size. (1) `server_prefill_enter` waited on `decode_pending > 0`, a *queued* token rather than an in-flight batch, so a steady stream of decode requests starved prompt work; (2) `decode_worker_main` gated only on `model_busy`, so a queued prefill could not stop the next decode batch from starting. Now both sit on one state read two ways: `server_decode_step_allowed_locked` (free executor **and** no prefill queued) and `server_prefill_step_allowed_locked` (free executor **and** my round-robin turn). A queued token stays withdrawable while it waits — `server_cancel_pending_decode_locked` touches no backend state — so removing the prefill's wait on it cannot strand it, and the two predicates share `model_busy` and the prefill queue, so they cannot deadlock. Decode does **not** get a slot between two chunks of the same prefill — see the field receipt in the pass conditions below. **Chunk:** `--mixed-prefill-quantum` now defaults to `0` = "do not shrink"; a positive value is a **chunk-size knob only**, because under strict priority it does not make a waiting decode step arrive sooner. The GLM-5.3 1024 floor and the round-robin between two prefills are untouched. Tests: new `test_prefill_preempts_decode` (mutation-checked both ways: drop the prefill-queue clause from the decode gate → 1 assertion red; restore the queued-decode wait in the prefill gate → 3 red) and `test_mixed_prefill_quantum_option` rewritten for the new default (0 keeps the wide chunk while a peer generates, the engine cap applies in both states, an explicit cap binds only while generating). `ds4_test --server` → `ds4 tests: ok`. **Deviation from "local patches touch `ds4_server.c` only": one line in `ds4_help.c`, so `--help` stops advertising the old 128 default.** **Pass conditions for the live smoke — result 2026-11-24 (the owner restarted onto the build himself):** startup prints `mixed_prefill_quantum=2048` — **PASSED**, the old binary prints `128`; no `chunk 128/…` line survives anywhere in the run — **PASSED**, every chunk is 2048 while a peer decodes; the peer's `decoding` lines pause instead of interleaving — **PASSED**. **And the bound I predicted does not exist:** a 23,395-token prefill (34.414 s, avg 679.81 t/s) froze the peer's decode **39 s** (`chunk=1.27 t/s`; its cumulative average fell 32.93 → 27.73 t/s), and a 191,211-token rebuild (279.792 s, avg 683.40 t/s, peak chunk 1076 t/s) froze it **283 s** (`chunk=0.18 t/s`). The release-to-requeue window is shorter than the decode worker's wake-up, so strict priority holds for the whole prompt. Prompt throughput is up ~3–7× on this shape (683 t/s against 90–210 t/s in the 128 era); the peer's cost is a full stall instead of the old ~13.6 t/s trickle. **Bounding that hold is a separate mechanism (a deliberate yield every N chunks), not a flag value. DECIDED 2026-11-24 — the owner chose "prompt work always wins", so the yield is declined, the stall is the design, and no later session should "fix" it; that ruling also answers the parked HANDOFF 35 "bounded halting" item.** One unverified lead: decode resumed ~5 s after `prompt done`, with a `reason=near-tail` store (7,353 MiB, `save=1773.9 ms`) plus one `near-tail-bound` eviction inside that gap; I did not read that path, so whether the store holds the executor is unknown | ours, no PR |
| **B20** | `patches/0019-kv-checkpoint-key-and-prompt-write-rule.patch` | **a checkpoint is keyed by the rendering the client replays, and the frontier write measures the prompt instead of the reused count, with every refusal printed.** Two failures, both measured on the owner's own restarts on 2026-11-25. **(1) The key:** the stop and slot-switch writes (`kv_cache_store_current` from `evict` `ds4_server.c:14803` and `shutdown` `:17492`) take their key from `kv_cache_visible_checkpoint` (`:11973`), which returned only `responses_live.visible_text` — the **answer rendering**. `build_responses_visible_assistant_suffix` (`:13791`) puts reasoning into that rendering only on a turn that carries tool calls, so a tool-free answer stored an answer-only key, while the client replays the **reasoning** rendering the server already keeps (`:10856`) and the live tier already tests (`:12470`). The disk tier has one key per file and took the one the client never sends. Measured on the files: the 19:44:09 stop wrote `81c9ac87` (139,499 tokens, 479,704 B) for the conversation that resumed at 139,537 tokens, and the two texts agree only to **byte 477,174**, so **94,974 tokens ran again**; the 17:36 stop (`7f7e7c89`, 297,493 tokens) agreed to byte 982,717 of 984,781 and cost **295,465 tokens in 623.850 s**. **Now:** `slot_reuse` carries `visible_surface` (0 = answer, 1 = reasoning), the probe sets it where it binds, the execution path copies it into `responses_live.answer_only_disk_key` under `tool_mu`, and the selector prefers the reasoning rendering until a request proves the client replays without it — the policy this file already applies to `thinking_live.token_text_disk_key`. The store log prints `key=responses-visible-reasoning`, so the operator sees which text was used. **(2) The write that never fired:** `kv_cache_maybe_store_prompt_tail` (`:11934`) gated on `prompt->len − max(cached, cold_saved) ≥ chunk`, and `cached` is `reuse.reuse_tokens`, which the visible tier sets to the **live KV position** (`:12478`) — longer than the replay whenever hidden reasoning is dropped — so the gate never opened. Measured: **no `near-tail` file of that conversation between 18:06:17 and 19:47:31**, while its prompt grew 44,563 → 139,499 tokens, with no line printed. **Now:** the slot carries `neartail_last_store_tokens`, the gate measures against it (or this request's cold prefix), and a refused store prints `prompt checkpoint not written reason=store-refused prompt=… covered=… chunk=…`. **Test:** `test_visible_checkpoint_keys_disk_by_replayed_rendering` (both renderings present → reasoning; a request proven on the answer rendering → answer; no summary emitted → answer). Mutation-checked: forcing the answer rendering turns two assertions red at `ds4_server.c:22770` and `:22772`. **Not in this patch, both on purpose:** cheap always-current checkpoints (the full-snapshot cost is 113.6 MiB + 33.33 KiB per token, so 4.61 GiB per write at 141,538 tokens — the compartment format in the vault design doc §5.1), and the reachability of the `continued` ladder for this client (its token decode stops matching the request text at byte 287,796 of 458,664, because it carries reasoning and tool text the client never replays). **Touches `ds4_server.c` only** | ours, no PR |
| **B21** | `patches/0020-kv-checkpoint-provenance-frame-and-startup-sweep.patch` | **a checkpoint now says which server wrote it, and the store is swept at startup against that answer: any file whose format version, payload ABI, or provenance frame is not this server's is deleted before the first request.** One patch, two halves, because the owner ruled them together: "*Fucking combine them both into 0020. i don't want to maintain tiny individual patches that do discrete things. combine them where they make sense. 20 patches to maintain on an inference engine is already an insane number*" and "*0020 needs to delete the checkpoint files if the KV_CACHE_VERSION != the server's current version **OR** if the yarn/quant/etc stuff do not match exactly.*" **Half one, the frame.** The fixed header named no rotary frame, so a YaRN-2.0 file and a native file were byte-identical to any reader; the field proof is the 512k launcher bug (`089cdbb`) that ran 524,288 on the native frame and wrote 10 files / 83 GiB into a YaRN-labelled directory, and the only thing that ever stopped a wrong-frame load was the one-directional context filter at `ds4_kvstore.c:1482`. **Header bytes 21-23 were free** (`fill_header` memset them, `read_header` never read them) and now carry a 24-bit **frame id**: the store's own SHA-1, truncated, over the 137 bytes the engine actually computed (`ds4_qwen4_rope_frame_bytes()` — the 32 derived inverse frequencies, the mscale, the native context, the YaRN flag), plus `model_id`, the routed-expert `quant_bits`, the context, the model file's `st_size` and its first 24 GGUF header bytes. **The derived table, never the setting** — any factor, mscale recipe or partial-rotary change lands in the digest with no new flag — and **never a path or an mtime**, because moving a model file must not invalidate a store. `KV_CACHE_VERSION` goes **1 → 2** in the same breath, so a pre-frame server refuses these files instead of guessing. **Half two, the sweep.** `kv_cache_refresh` reads every header and pushes only on success, with no `else`, so a file whose header fails is dropped **silently** — and because every budget and eviction sum walks the indexed entries, it **occupies real disk while counting as zero against the store budget**: invisible, uncounted, never freed. `kv_cache_sweep_version()` therefore runs from `ds4_kvstore_open` **before** the first eviction pass (reached once, `kv_cache_open` at `ds4_server.c:11564`, called at `:17464`, with the frame set at `:17462`), and **startup only is correctness, not caution**: a file mid-write has no valid header until its write completes, so sweeping inside the periodic refresh would unlink a live write out from under its own writer. **Strict as ruled** — newer *and* older are both removed, no version flag, no escape hatch; the downgrade ratchet was raised and accepted, and the sweep line is the only record. Rails kept because they are correctness: only names matching the store's own 40-hex `.kv` pattern are eligible, `lstat` requires a regular file so a symlink is never unlinked in place of its target, and a failed `unlink` prints. **The flag:** `--kv-cache-reject-different-quant` is repurposed, not deleted — **ten** scripts pass it (`run.sh`, `start.sh` and the eight `start-*.sh` profiles), so removing it would stop every one of them starting. Its old job was a load-time quant comparison, and that comparison is **gone from this patch** (`kv_cache_existing_compatible`, the near-tail compatibility test, the eviction context field, and the `find_text_prefix` skip): a foreign quantization no longer survives boot. The bare form now means *enforce*, which is also the default, and `=off` means **report-only** — every would-be deletion prints, nothing unlinks. **Consequences, stated before the swap:** the version bump means **the first start on any existing store deletes every checkpoint in it** (the wipe operators were doing by hand, now done by the server); and because the context is inside the digest, **changing `--ctx` empties the store at the next start** too. **Log:** one line per removal (`reason=unreadable\|bad-magic\|version\|payload-abi\|frame`, or `would remove` in report-only) plus a summary with the mode, the build's version and ABI, `frame=%06x`, per-class counts and `freed=N bytes (G GiB)`; the `KV disk cache` startup line gained `frame=%06x sweep=enforce\|report-only` in place of `cross-quant=…`, so a profile/directory mismatch is visible at boot instead of in degraded answers weeks later. **Touches 7 files** (`ds4.c`, `ds4.h`, `ds4_kvstore.c/.h`, `ds4_server.c`, `ds4_help.c`, `tests/test_kvstore_near_tail.c`) — the runbook's "local patches touch `ds4_server.c` only" rule is broken again by design and stated here, precedent `0009` (4 files). **Verification:** `./build.sh` exit 0, **27/27 `applied (clean)`**, `codesign -v` silent, binary `6475fa17…` (identity is the commit, not the digest); byte-identity **`IDENTICAL` ×7** against the tree that ran the tests; `ds4_test --server` → `ds4 tests: ok`; `test-kvstore-near-tail` **PASS** with the new sweep fixture (report-only unlinks nothing and prints `would_remove=5`; enforce removes the four envelope failures and the foreign frame, keeps the matching file and the non-`40hex.kv` name, and the summary's `freed=` equals the bytes actually gone; a store opened by another frame deletes the file the first frame kept; a checkpoint written by this server carries this server's frame and version) — **three mutations, three reds**: drop the frame assignment in `open`, make the sweep always enforce, drop the stamp on the store path; artifact probes on the installed binary: `kv cache sweep` ×4, `frame=%06x` ×2, `would_remove=%d` present, `cross-quant` **gone**; the flag contract proven on the binary — the bare form and `=off` parse, `=bogus` prints `invalid value for --kv-cache-reject-different-quant: bogus` and exits 2. **Step 4 owed: the owner's restart** (C5 — the server that would be restarted is the one serving this agent), and the first line to read afterwards is the `kv cache sweep …` summary | ours, no PR |

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
| Our patches | `patches/` | `0001`…`0004`, `0006`…`0020` (0005 is archived), numbered; next free is `0021` — and the standing rule (owner, 2026-11-26) is to **extend the patch whose concern it belongs to rather than mint a new number for every discrete change** |
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
`docs/RESPONSES_CACHE_MISS.md` §13: `kv_cache_tail_admit()` needs whole-store free space,
while the main pool runs the store to its 240 GiB budget. **Mechanism corrected 2026-11-24**
(my 2026-11-22 wording said the pool "never evicts", which is wrong): the pool has its own
share (`kv_cache_tail_budget` = `min(budget/8, 16 GiB × resident_sessions)`) and it does
evict near-tail files (`kv_cache_tail_prune`, `evicted reason=near-tail-bound`, 25 lines in
that log, latest 23 Nov 21:43) — but the prune runs only *after* a successful store
(`ds4_kvstore.c:1376`), so a store already at budget refuses before any prune can help.
Re-measured 24 Nov: the store is nearly empty (1 file, 314 MB), near-tail writes resumed
(7 on 23 Nov, 1 on 24 Nov) and refusals resumed with them (10 across 23–24 Nov) — the
starvation returns within hours of heavy vision use, not after eight days. The cheapest
immediate answer is `--kv-disk-space-mb` (240 GiB today, 622 GiB free on the volume). **The
appended-screenshot resume is still owed** — the splice has never run in the field.
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
B19 ran the same day and PASSED on all three stated conditions** (owner restarted
onto the build at 13:44): `mixed_prefill_quantum=2048` at startup, no `chunk 128/…`
line in the run, and the peer's decode pausing rather than interleaving. **It also
falsified the bound this patch's own text claimed:** a held generation waits for the
whole prompt (39 s for a 23,395-token prefill, 283 s for a 191,211-token rebuild), not
one chunk. The comments in `0018`, `docs/SERVER.md` and the B19 row now carry the
measurement. **Ruling the same day: "prompt work always wins" — the bounded yield is
declined, so the stall stands (design constraint C7 in the vault design doc).**

**Re-verified 2026-11-25 for B8 rewritten** (the patch that owns the supplementary
pool's standing, renamed from `…-sizes-with-resident-sessions`; store code only, no
format change, so the 240 GiB store stays warm). Step 1: `./build.sh` → exit 0,
`b3f5018` + 8 upstream + 17 local, **all 25 applies `applied (clean)`** — including
`0010`–`0018`, which sit after B8 and none of which touch `kv_cache_tail_admit` or
`ds4_kvstore_entry_eviction_score` (0 matches each, which is why extending B8 instead
of adding a patch was safe). Step 2: byte-identity — a throwaway worktree at
`b3f5018` + the 8 upstream + `0001`–`0008` + the committed `0009` matches the tested
tree in **all four** files it touches (`ds4_kvstore.c`, `ds4_kvstore.h`,
`ds4_server.c`, `tests/test_kvstore_near_tail.c`): `IDENTICAL` ×4. Step 3, run on both
the B8-only tree and the **full 25-patch chain**: `ds4_test --server` → `server: OK`,
`ds4 tests: ok`; `test-kvstore-near-tail` → `PASS`. The only warnings are the two
documented `-Wpointer-sign` lines at the B3 probe. `test-qwen-tool-disk-key` still
fails to compile at `tests/test_qwen_tool_disk_key.c:210` and `:231` with `too few
arguments to function call, expected 4, have 3` — **the same pre-existing break from
`0016` recorded above, unchanged by this patch.** Step 4 is **the swap and is owed**:
the running server is pid 46573 from 24 Nov 13:44 and it serves this agent, so the
restart is the owner's, fired detached per
`Procedures/ds4-restart-the-serving-server.md`. Pass conditions after the swap: (a)
with the store at its cap, `kv cache stored … reason=near-tail` appears instead of
`supplementary admission has no room`; (b) `kv cache evicted reason=disk-cache-full …
hits=0` names files last read long ago and not the newest frontier; (c) a switching
conversation's prefill falls from ~20,000 tokens to the new turn's tokens.

**B20 added 2026-11-26** (`0019`, `ds4_server.c` only; no format change, so the 240 GiB store stays warm). **Step 1:** `./build.sh` → exit 0, `b3f5018` + 8 upstream + **18 local**, **all 26 applies `applied (clean)`**, `codesign -v ./ds4-server` silent, and the installed binary carries both new strings (`strings ./ds4-server | grep -c` → 1 for `responses-visible-reasoning`, 1 for `prompt checkpoint not written`). **Step 2:** byte-identity — a throwaway worktree at `b3f5018` + the 8 upstream + `0001`–`0018` + the committed `0019` applies clean with no 3-way merge and matches the tested tree: `IDENTICAL ds4_server.c`. **Step 3:** `ds4_test --server` → `server: OK`, `ds4 tests: ok`; `test-kvstore-near-tail` → `PASS`; only the two documented `-Wpointer-sign` warnings; `test-qwen-tool-disk-key` unchanged at its pre-existing `0016` compile break. The new `test_visible_checkpoint_keys_disk_by_replayed_rendering` is mutation-checked: forcing the answer rendering turns `ds4_server.c:22770` and `:22772` red (`ds4 tests: 2 failure(s)`), and restoring it turns them green. **Also recorded here, because the entry above still says owed: B8 step 4 PASSED on 2026-11-25 17:37–17:51** — the owner swapped the box himself; `17:50:25 kv cache stored tokens=301609 … reason=near-tail … save=2215.4 ms` proves condition (a); every `disk-cache-full` eviction in that run carried `hits=0` and the 366,616-token never-read anchor `63eb70c9` left first, proving (b); `17:51:28 … cached=303303 prompt=318674` → `chat ctx=303303..318674:15371` proves (c). **Step 4 for B20 is the swap and is owed.** Pass conditions: (a) after a stop, the store holds a `shutdown` checkpoint whose store line reads `key=responses-visible-reasoning`; (b) the first request after that stop hits that file and prefills only the new turn, where this same conversation paid 94,974 tokens on 2026-11-25; (c) a refused frontier write prints `prompt checkpoint not written reason=store-refused` instead of staying silent; (d) no `identity miss`, `kv cache discarded`, or 500 appears in the run. The restart is the owner's, fired detached per `Procedures/ds4-restart-the-serving-server.md`, because the server being swapped serves this agent.

**B20 step 4 PASSED 2026-11-26 12:27** (owner stopped the server at 12:27:18 and restarted at 12:27:24, pid 37482, listening 12:27:28; the store had been wiped at 12:06:49, so nothing predated this build). **(a) passed** — `12:27:18 persisting resident KV cache before shutdown slot=1 tokens=136433` then `kv cache stored tokens=136433 trimmed=0 reason=shutdown key=responses-visible-reasoning size=4555.03 MiB save=629.4 ms`: the first live appearance of that key label. The other slot wrote `key=token-text` (106,034 tokens, 3,565.41 MiB, 331.7 ms) in the same stop, so the selector still distinguishes the tiers rather than relabelling everything. **(b) passed** — the header of that same file (`eafb5e44…`) reads `hits=1` with `last_used 12:27:48` against `created 12:27:19`, so the first request after the restart loaded it, and that request's own frontier (`2e0889ca`, keyed by its prompt text) holds 141,899 tokens: the resume covered **136,433 of 141,899**, so the turn cost **5,466 tokens** where the same shape cost **94,974** on 2026-11-25. **(d) passed** — no `identity miss`, `kv cache discarded`, prefill failure or 500 anywhere in the run. **(c) NOT exercised, still open** — no frontier write was refused, so `prompt checkpoint not written reason=store-refused` never had a cause to fire for; it stays owed until a pool at its share forces a refusal. **Method note, because it is the only way this was checkable:** the store's own headers are the evidence channel here — `server_log` writes stderr and a `| tee` capture holds only stdout, so the hit counters (`tokens @8`, `hits @12`, `created @24`, `last_used @32`) prove the read path where the log file proves nothing.

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
