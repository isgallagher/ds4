#!/bin/bash
# build.sh — reproducible local build:
#   1. fetch the latest upstream main from antirez/ds4 (anonymous HTTPS)
#   2. apply the upstream PR patches, then our local patches, in a throwaway worktree
#   3. build ./ds4-server, install it, ad-hoc re-sign it
#
# Nothing here touches the working tree or any branch. The build is
# deterministic for a given (upstream commit + patch set): re-run it any time.
#
# RUNBOOK: docs/BUILD_PATCHES.md — the safety behaviors, how to update a
# patch, what to do when upstream moves or absorbs a PR, and how to swap the
# live server. Read it before changing patches/ or this script.
#
# ---------------------------------------------------------------------------
# THE CONTRACT (applied in this exact order)
#
# A. Upstream PRs we build on, not yet merged upstream (patches/upstream/).
#    These are other people's diffs, stored verbatim so the build needs no
#    network beyond the main fetch. Pinned heads (2026-10-16):
#
#   upstream/pr1175.patch        PR #1175 @ 4e8706d — validate the parent
#                                history before the live tool-ID shortcut.
#   upstream/pr1169.patch        PR #1169 @ 395a3ed — preserve sampled tool-call
#                                spans/IDs across checkpoint restore; align
#                                committed EOS, continuation tails, visible keys.
#   upstream/pr1206-integrated.patch
#                                PR #1206 @ a08bce5 — preserve the Qwen Responses
#                                live frontier when the client replays an emitted
#                                final-answer reasoning summary (also covers
#                                clients that omit it). STORED INTEGRATED: the
#                                raw PR conflicts with #1175 in two places and
#                                leaves one call site short an argument; this
#                                file carries those three resolutions folded in,
#                                so the build never sees conflict markers.
#                                Supersedes our old patch 0005 (see archive/).
#   upstream/pr1200.patch        PR #1200 @ d18057e — save eligible completed
#                                text-only Qwen Responses prompts as a
#                                `near-tail` checkpoint before generation.
#   upstream/pr1212.patch        PR #1212 @ a05decc — fix the Qwen Chat tool-turn
#                                disk checkpoint key for reasoning-echo
#                                histories (fixes #1211): the turn used to
#                                persist a reasoning-free alias, so the next
#                                return could not match the checkpoint. Same
#                                class as our 2026-10-16 20:12:17 and 20:35:32
#                                misses.
#   upstream/pr1216.patch        PR #1216 @ 402c80b — pick the LONGEST text-
#                                prefix disk checkpoint in one pass instead of
#                                the first one that beats the current best, and
#                                stop re-hashing the prompt per candidate.
#                                Measured need: 2026-10-16 20:35:32, where the
#                                miss path knew the divergence sat at token
#                                40297 and still loaded the 29580 checkpoint
#                                (40,610 tokens re-prefilled).
#   upstream/pr1221.patch        PR #1221 @ 2b720e8 — let the memory-text tier
#                                survive images (fixes #1214: the request's
#                                DS4_IMAGE_<nonce> marker vs the checkpoint's
#                                expanded vision run made that tier dead).
#   upstream/pr1197.patch        PR #1197 @ cea545e — accept WebP images on
#                                macOS through ImageIO. Pasted/clipboard images
#                                arrive as WebP and the server answered a
#                                generic 400. Vision input fix, no new
#                                dependency, Apple-only path.
#
#    Upstream tracker for A: issue #1201. Merge order there is
#    1175 -> 1169 -> 1206 -> 1200, with "#1206 must merge after #1169".
#    1212 and 1216 join that workstream from outside the tracker; 1197 is
#    independent (image decode) and goes last.
#
#    Rejected from the same survey, with the reason (2026-10-16):
#      #1170  checkpoint selection + eviction, 25 KB. Overlaps #1216 on the
#             lookup we needed, conflicts with our 0002 disk guard (2 regions
#             measured), and interacts with #1200. Revisit if #1216 proves
#             insufficient.
#      #1168  speculative-drafting backoff, 70 KB, 2 conflict regions. MTP is
#             live here (--mtp); we hold --mtp-timing data to judge it on
#             first.
#      #1205  the GLM-5.3 only variant of our option C. Not applicable to Qwen.
#      #1153  new --image-prefix-snapshot flag for issue #1007. Conflicts with
#             0002; our 0004 already fixes the truncated-vision-block cause.
#
# B. Our own fixes (patches/):
#
#   0001-responses-accept-nonterminal-status.patch
#       Responses replay: accept non-terminal item status, drop unknown
#       item types (the "400 API" fix). No upstream PR.
#   0002-responses-heal-forked-checkpoint.patch
#       Responses fork-heal in the miss path (our PR antirez/ds4#1194):
#       skip the forked evict-store, reject a forked disk load, heal-sync the
#       canonical prompt. Kept as the safety net while #1169/#1175/#1170 aim
#       to prevent the forks in the first place.
#   0003-responses-cache-miss-probe.patch
#       Diagnostic (env-gated, DS4_CACHE_MISS_DEBUG=1): on a live KV cache
#       miss, dump the first-diff index plus a +/-32-token window (ids +
#       base64 text). No behavior change without the env var.
#   0004-responses-vision-block-continuation.patch
#       Copy the full vision block into the live KV continuation suffix, not
#       just the pads (tests/test_responses_image_read_repro.py).
#   0006-vision-embedding-cache-fingerprint-key.patch
#       Key the vision embedding cache on the pixel fingerprint (SHA-256 of
#       the decoded width/height/RGB, the same identity the KV tier matches)
#       instead of exact client bytes, so a client re-encoding the same
#       pixels turn to turn still hits. 0005 is archived (superseded by
#       #1206), so this patch takes the next free number.
#
# ARCHIVE: patches/archive/0005-…superseded-by-pr-1206.patch — our FIX-1. The
# visible-suffix gate change is replaced by #1206's two-key design, which also
# covers clients that omit the reasoning. Kept for the record; not applied.
# ---------------------------------------------------------------------------
#
# Upstream branch is `main` (origin/HEAD), not `master`.
#
# Fetch note (this machine): SSH to github.com times out and a global
# url.insteadOf rewrite forces SSH for HTTPS too, so a plain
# `git fetch origin` hangs. The fetch below bypasses the global config
# and goes anonymous over HTTPS; antirez/ds4 is public, so no credential
# is needed. If you run on a machine where `git fetch origin main` works
# normally, the bypass is harmless (it just also works).
#
# Usage:
#   ./build.sh                 # build ./ds4-server from upstream main + patches
#   REF=<sha> ./build.sh       # build from a specific upstream commit instead
#
# If a patch no longer applies, the build STOPS with the patch named and a
# `git apply` error — resolve it deliberately (docs/BUILD_PATCHES.md) rather
# than letting a half-applied tree build. Two patches legitimately need a
# 3-way merge (1169 over 1175); apply() does that automatically and then
# refuses to continue if any conflict marker survived anywhere in the tree.

set -euo pipefail
cd "$(dirname "$0")"

REF="${REF:-main}"
UPSTREAM="https://github.com/antirez/ds4.git"

# --- 1. Fetch latest upstream (anonymous HTTPS; bypass the global insteadOf) ---
echo "fetching upstream ${REF} ..."
FRESH=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        git -c credential.helper= fetch --quiet "${UPSTREAM}" "${REF}" \
        && git rev-parse FETCH_HEAD)
echo "upstream ${REF} = ${FRESH}"

# --- 2. Throwaway worktree at that upstream commit, patches applied ---
WT=$(mktemp -d /tmp/ds4-build-XXXXXX)
trap 'git worktree remove --force "${WT}" 2>/dev/null || rm -rf "${WT}"; git worktree prune 2>/dev/null' EXIT
git worktree add --detach "${WT}" "${FRESH}" >/dev/null

# Each patch is committed before the next one is applied: the 3-way fallback
# needs an index that matches HEAD, and the per-step commit is also what makes
# "which patch broke the tree" answerable when one stops the build.
apply() {
    local p="$1"
    local abs; abs=$(cd "$(dirname "$0")" && pwd)/${p}
    : > /tmp/ds4-build-apply.err
    if git -C "${WT}" apply "${abs}" 2>>/tmp/ds4-build-apply.err; then
        echo "applied (clean):  ${p}"
    elif git -C "${WT}" apply -3 "${abs}" 2>>/tmp/ds4-build-apply.err; then
        echo "applied (3-way):  ${p}"
    else
        echo "" >&2
        echo "PATCH DOES NOT APPLY on upstream ${FRESH}: ${p}" >&2
        echo "(upstream or the cluster moved; see docs/BUILD_PATCHES.md §Rebasing a patch," >&2
        echo " or pin with REF=<old-sha>)" >&2
        sed -n '1,40p' /tmp/ds4-build-apply.err >&2
        exit 1
    fi
    # A 3-way merge can succeed while leaving conflict markers behind.
    # Never compile that: it fails with a confusing syntax error instead.
    if git -C "${WT}" grep -l -e '^<<<<<<< ' -e '^>>>>>>> ' -- . > /tmp/ds4-build-conflicts.txt 2>/dev/null; then
        echo "" >&2
        echo "CONFLICT MARKERS LEFT BY ${p} — refusing to build:" >&2
        sed -n '1,20p' /tmp/ds4-build-conflicts.txt >&2
        exit 1
    fi
    git -C "${WT}" add -A
    git -C "${WT}" -c user.email=build@local -c user.name=build \
        commit -q -m "build.sh apply ${p}" >/dev/null
}

echo "applying upstream PR patches (issue #1201 order) ..."
apply patches/upstream/pr1175.patch
apply patches/upstream/pr1169.patch
apply patches/upstream/pr1206-integrated.patch
apply patches/upstream/pr1200.patch
apply patches/upstream/pr1212.patch
apply patches/upstream/pr1216.patch
apply patches/upstream/pr1221.patch
apply patches/upstream/pr1197.patch

echo "applying local patches ..."
apply patches/0001-responses-accept-nonterminal-status.patch
apply patches/0002-responses-heal-forked-checkpoint.patch
apply patches/0003-responses-cache-miss-probe.patch
apply patches/0004-responses-vision-block-continuation.patch
apply patches/0006-vision-embedding-cache-fingerprint-key.patch

# --- 3. Build in the worktree ---
# CC must be /usr/bin/clang: the default `cc` on this box is a nix LLVM shim
# that fails on ds4_metal.m.
echo "building ds4-server ..."
make -C "${WT}" -j"$(sysctl -n hw.ncpu)" CC=/usr/bin/clang ds4-server

# --- 4. Install the binary over ./ds4-server (run scripts exec ./ds4-server) ---
cp "${WT}/ds4-server" ./ds4-server
chmod +x ./ds4-server
# Ad-hoc re-sign after the copy: an unsigned/copy-modified binary is SIGKILLed
# at startup by macOS code signing ("Invalid Page" inside dyld). See
# docs/BUILD_PATCHES.md §Swapping the live server.
codesign --force -s - ./ds4-server
echo "done: ./ds4-server built from upstream ${FRESH} + 8 upstream PR patches + 5 local patches"
echo "run:  ./start-qwen38-longctx.sh   (runbook: docs/BUILD_PATCHES.md)"
