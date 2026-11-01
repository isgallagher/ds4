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
| Build script | `~/repos/ds4/build.sh` | fetch → patch → build → install → re-sign |
| Upstream PR patches | `patches/upstream/` | stored verbatim diffs, pinned by the SHAs above |
| Our patches | `patches/` | `0001`…`0004`, `0006`…`0012` (0005 is archived), numbered; next is `0013` |
| Archived patch | `patches/archive/` | kept for the record, never applied |
| Upstream repo | `origin` = `git@github.com:antirez/ds4` (SSH — unusable on this box, see §Fetch) | upstream branch is **`main`**, not `master` |
| Local fix branch | `fix/responses-replay-status-tolerance` | carries `build.sh` + `patches/` + docs; **not** pushed |
| PR branch (clean artifact) | `pr/responses-fork-heal` (fork `isgallagher/ds4`, PR #1194) | single code commit only. **Never** put `build.sh`/`patches/`/private docs on it |
| Running server | `pgrep -f "ds4-server --ctx"` | one server at a time on this box |
| Debug launcher | `~/.ds4/fc-debug/start-probe-trace.sh` | probe env + `--trace`, capture home `~/.ds4/fc-debug/` |

## The safety behaviors (what build.sh does on purpose)

1. **A patch that won't apply → hard stop, before compiling.** `apply()` tries a
   plain `git apply`, then a 3-way (`-3`) apply, and stops with the patch name
   and the error if both fail. Never let a half-applied tree build. Your options,
   in order: pin (`REF=<sha> ./build.sh`), or rebase the patch (§Rebasing).
2. **Conflict markers are a build error.** A 3-way merge can "succeed" while
   leaving `<<<<<<<` markers in the file. After every patch `apply()` greps the
   whole tree for markers and stops if any survive, so you get "CONFLICT MARKERS
   LEFT BY <patch>" instead of a confusing syntax error three minutes later.
3. **Each patch is committed in the worktree before the next is applied.** The
   3-way fallback needs an index matching HEAD, and the per-step commit makes
   "which patch broke this tree" answerable.
4. **Order matters and is fixed.** Group A in tracker order, then group B in
   number order. Keep the numbering: the next free local patch number is
   `0011` (0005 is archived), and its `apply` line goes after the existing ones.
5. **The working tree is never a build input.** The build happens in a throwaway
   `git worktree` at the fetched upstream commit; only `./ds4-server` comes back
   out, and `codesign --force -s -` runs on it (see §Swapping the live server).
6. **`REF=<sha>` pins the upstream side.** `REF=fc80bd6 ./build.sh` reproduces
   the 2026-10-16 build regardless of what upstream does. Use it to separate
   "upstream moved" from "my patch changed".

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

`build.sh` stops and names the failing patch. Two moves:
- **Temporary:** `REF=<last-known-good-sha> ./build.sh`.
- **Proper (rebase the patch):**
  1. `git worktree add /tmp/ds4-rebase <new-main-sha>` (detached).
  2. Apply the earlier patches in order, then `git apply --check` the failing
     one. The error and hunk context show what upstream changed around the fix.
  3. Edit the patch (or regenerate it against the new base) so it applies.
  4. `git worktree remove --force /tmp/ds4-rebase`; run `./build.sh`; verify.

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
