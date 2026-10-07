# ds4 — patch-based build runbook

`build.sh` + `patches/` make the local combined build reproducible: **fetch upstream
`main` → apply the two patches → build `./ds4-server`**, without touching the working
tree or any branch. The **patch files are the build contract**, not any branch:
the build is deterministic for a given (upstream commit + patch pair).

This file is the runbook for changing that contract. Read it before editing
`build.sh`, `patches/*`, or swapping the running server.

## Where everything lives

| Artifact | Path | Notes |
|---|---|---|
| Build script | `~/repos/ds4/build.sh` | fetch → patch → build → install |
| Patch 1 (400 fix) | `patches/0001-responses-accept-nonterminal-status.patch` | accepts non-terminal status + drops unknown item types on Responses replay |
| Patch 2 (fork-heal) | `patches/0002-responses-heal-forked-checkpoint.patch` | the fork-heal; **byte-identical to PR antirez/ds4#1194's diff** |
| Upstream repo | `origin` = `git@github.com:antirez/ds4` (SSH — unusable on this box, see §Fetch) | upstream branch is **`main`**, not `master` |
| Local fix branch | `fix/responses-replay-status-tolerance` | carries `build.sh` + `patches/` + full history; **not** pushed to anywhere |
| PR branch (clean artifact) | `pr/responses-fork-heal` (fork `isgallagher/ds4`, PR #1194) | single code commit only. **Never** put `build.sh`/`patches/`/private docs on it |
| Running server | `pgrep -f "ds4-server --ctx"` → started by `./start-qwen38-longctx.sh` | one server at a time on this box |

## The safety behaviors (what build.sh does on purpose)

1. **Upstream moved and a patch won't apply → hard stop.** `git apply --check`
   runs before each patch; failure prints the patch name and the hunk error, then
   exits **before compiling**. Never let a half-applied tree build. Your options,
   in order: pin (`REF=<sha> ./build.sh`), or rebase the patch onto the new main
   (§Rebasing a patch).
2. **Order matters and is fixed.** Patches apply in the order of the `apply`
   calls in `build.sh` (0001 then 0002). They touch disjoint regions of
   `ds4_server.c` and are independent, but keep the numbering: next patch is
   `0003-…`, and add its `apply` line after the existing ones.
3. **The working tree is never a build input.** Build happens in a throwaway
   `git worktree` at the fetched upstream commit; only `./ds4-server` comes back
   out. Uncommitted local work cannot leak into the build — and nothing in the
   build can clobber it. (This is also why `build.sh` must not `git checkout`
   anything in the main tree.)
4. **`REF=<sha>` pins the upstream side.** `REF=0aaea5a ./build.sh` reproduces
   the exact build made on 2026-10-07 regardless of what upstream does. Use it
   to isolate "did upstream move or did my patch change".

## The three change scenarios

### A. One of the fixes changes → regenerate its patch

A patch is just a diff of `ds4_server.c`. Regenerate it from the commits that
define the fix, then prove the pipeline still works:

```sh
cd ~/repos/ds4
# 0001 = 400-fix commit against the upstream base it was cut from:
git diff 0aaea5a 10e2a71 -- ds4_server.c > /tmp/0001.patch
# 0002 = the PR branch's diff against upstream main:
git diff origin/main pr/responses-fork-heal -- ds4_server.c > /tmp/0002.patch
# sanity: identical to the committed patches before you replace them
diff /tmp/0001.patch patches/0001-responses-accept-nonterminal-status.patch
diff /tmp/0002.patch patches/0002-responses-heal-forked-checkpoint.patch
# replace, rebuild, verify (§Verification after any build change)
```

Rules of thumb:
- Keep each patch **one concern, one file** (`ds4_server.c` only, for now).
- Cut a new patch from the **PR branch** when the fix is PR-bound (that keeps
  the patch and the PR in lockstep); cut from the local commit otherwise.
- The committed patch files and the running branch are cross-checks on each
  other: `./build.sh`'s output must stay byte-identical to the fix branch's
  `ds4_server.c` while the patches and the branch agree (§Verification).

### B. PR #1194 lands upstream → drop patch 0002

When the fork-heal merges into `antirez/ds4` `main`:
1. Remove the `apply patches/0002-…` line from `build.sh` (and the patch file,
   or keep it for the record under `patches/archive/`).
2. Re-run `./build.sh` — if you forgot to drop it, the hard stop in
   safety-behavior 1 catches it (a patch that's already upstream fails
   `--check`), so a green build is the confirmation.
3. Update this table and the commit message of the change.

The 400 fix has **no** upstream PR; its patch stays until/unless it gets one.
If the 400 fix ever lands upstream too, it exits the same way (drop 0001).

### C. Upstream main moved and 0001/0002 no longer apply

`build.sh` stops and names the failing patch. Two moves:
- **Temporary / don't care yet:** `REF=<last-known-good-sha> ./build.sh`.
- **Proper (rebase the patch):**
  1. `git worktree add /tmp/ds4-rebase <new-main-sha>` (detached).
  2. `git -C /tmp/ds4-rebase apply -v <patch>` — it will fail; the `--check`
     output and the hunk context show what upstream changed around the fix.
  3. Edit the patch by hand (or regenerate via scenario A against the new
     base) so it applies cleanly on the new main.
  4. `git worktree remove --force /tmp/ds4-rebase`; run `./build.sh`; verify.
  The fix's *logic* doesn't change during a rebase — only its context lines.
  If a hunk needs a logic change, stop: that's a new bug/interaction, not a
  rebase.

## Verification after any build change

Run in this order; a change is "done" when all four pass:
1. `./build.sh` → exit 0, "done: ./ds4-server built from upstream <sha> + 2 patches".
2. **Byte-identical invariant** (patches vs the fix branch — catches a stale
   patch file):
   ```sh
   WT=$(mktemp -d /tmp/ds4-eqv-XXXXXX)
   git worktree add --detach "$WT" origin/main
   git -C "$WT" apply -v patches/0001-responses-accept-nonterminal-status.patch
   git -C "$WT" apply -v patches/0002-responses-heal-forked-checkpoint.patch
   diff -q "$WT/ds4_server.c" "$(git rev-parse --show-toplevel)/ds4_server.c" && echo IDENTICAL
   git worktree remove --force "$WT"
   ```
   (Hunk offset notes in the apply output are normal — 0002 shifts by 0001's
   net line change; `git apply` handles it.)
3. `make -C <a clean worktree or the repo> ds4_test && ./ds4_test --server`
   → `ds4 tests: ok`. (In the repo tree; the throwaway worktree is gone.)
4. Live smoke on the port: a `/v1/responses` tool round trip completes with no
   400 (that exercises the 400 fix), and the server log shows normal
   `responses live continuation` hits. The fork-heal's own engagement is only
   visible under a forked-history repro (see
   `docs/RESPONSES_REPLAY_MISS_TEST.md` for the harness + repro scripts, if
   still in `/tmp/fc-debug/`).

## Swapping the live server onto a fresh build

```sh
pkill -f "ds4-server --ctx"          # one server at a time on this box
cd ~/repos/ds4 && ./build.sh
./start-qwen38-longctx.sh > /tmp/fc-debug/server.log 2>&1 &   # (detach properly)
pgrep -f "ds4-server --ctx"          # new pid
```
`./start-qwen38-longctx.sh` execs `./ds4-server`, so "the build" and "the
running server" are the same artifact once swapped. Restarting mid-owner-session
needs the owner's go (standing go exists for the capture/work server, not for
an owner's live session).

## Fetch: why the env gymnastics are load-bearing

On **this machine** `git fetch origin` cannot work: `origin` is SSH, SSH to
github.com times out (port 443 blocked), and a **global**
`url.git@github.com:.insteadOf https://github.com/` rewrites even explicit
HTTPS fetches back to SSH. `build.sh` therefore fetches anonymously over HTTPS
(repo is public) with the global config bypassed:
`GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -c credential.helper= fetch https://github.com/antirez/ds4.git main`.
On a machine without those quirks the same command still works (public repo,
no credential needed) — don't "clean it up" per-machine without re-reading this
section. Pushing to the fork has the same SSH problem; the working form is
`git -c credential.helper= push https://isgallagher:$(gh auth token)@github.com/isgallagher/ds4.git <branch>`.

## Do-not list

- Don't add `patches/` or `build.sh` to `pr/responses-fork-heal` (the PR
  artifact stays a single code commit).
- Don't commit `patches/` changes without the §Verification four-step.
- Don't re-derive the fork-heal by copying files between the PR branch and the
  fix branch — that's how the 400 fix was silently dropped once (2026-10-07,
  recorded in `Projects/ds4/progress.md`). Regenerate patches from commits;
  verify with `diff -q`.
