# ds4 — patch-based build runbook

`build.sh` + `patches/` make the local combined build reproducible: **fetch
upstream `main` → apply the upstream PR patches → apply our patches → build
`./ds4-server` → install + re-sign**, without touching the working tree or any
branch. The **patch files are the build contract**, not any branch: the build is
deterministic for a given (upstream commit + patch set).

This file is the runbook for changing that contract. Read it before editing
`build.sh`, `patches/`, or swapping the running server.

## The contract today (2026-10-16)

Two groups, applied in this order. Group A is other people's upstream PRs that
we build on while they wait for merge; group B is our own fixes.

| # | File | What | Upstream state |
|---|---|---|---|
| A1 | `patches/upstream/pr1175.patch` | validate parent history before the live tool-ID shortcut | PR #1175 @ `4e8706d`, open |
| A2 | `patches/upstream/pr1169.patch` | preserve sampled tool-call spans/IDs across checkpoint restore; align committed EOS, tails, visible keys | PR #1169 @ `395a3ed`, open |
| A3 | `patches/upstream/pr1206-integrated.patch` | preserve the Qwen Responses live frontier when the client replays an emitted final-answer reasoning summary (and when it does not) | PR #1206 @ `a08bce5`, open — **stored integrated**, see §Why A3 is not the raw PR |
| A4 | `patches/upstream/pr1200.patch` | save eligible completed text-only Qwen Responses prompts as a `near-tail` checkpoint before generation | PR #1200 @ `d18057e`, open |
| A5 | `patches/upstream/pr1221.patch` | let the memory-text tier survive images (fixes #1214) | PR #1221 @ `2b720e8`, open |
| B1 | `patches/0001-responses-accept-nonterminal-status.patch` | accept non-terminal item status + drop unknown item types on Responses replay (the "400 API" fix) | ours, no PR |
| B2 | `patches/0002-responses-heal-forked-checkpoint.patch` | fork-heal in the miss path | ours, **PR antirez/ds4#1194** (draft) |
| B3 | `patches/0003-responses-cache-miss-probe.patch` | `DS4_CACHE_MISS_DEBUG=1` first-diff window on a miss (diagnostic only) | ours, diagnostic |
| B4 | `patches/0004-responses-vision-block-continuation.patch` | copy the full vision block into the live KV continuation suffix | ours, no PR |

- **Tracker for group A:** upstream issue #1201. Its merge order is
  `1175 → 1169 → 1206 → 1200`, with "#1206 must merge after #1169" (it relies on
  #1169's EOS commitment). `build.sh` applies in that order.
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
| Our patches | `patches/` | `0001`…`0004`, numbered; next is `0005` |
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
   number order. Keep the numbering: a new local patch is `0005-…` (0005 is
   archived, so the next free number is `0006`), and its `apply` line goes after
   the existing ones.
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
4. Live smoke on the port: a `/v1/responses` tool round trip completes with no
   400 (B1), and the log shows normal `responses live continuation` hits. The
   fork-heal (B2) only shows up under a forked-history repro, and the reuse
   tiers from group A show up in `~/.ds4/fc-debug/` trace captures.

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
- Don't assume the fix branch's `ds4_server.c` is what builds. It is based on
  `0aaea5a` and is a carrier for `build.sh`/`patches/`/docs; the binary is
  upstream-tip + patches. The §Verification step 2 comparison is against the
  tested tree, not against the branch file.
