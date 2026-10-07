#!/bin/bash
# build.sh — reproducible local build:
#   1. fetch the latest upstream main from antirez/ds4 (anonymous HTTPS)
#   2. apply the two local patches (in order) onto a throwaway worktree
#   3. build ./ds4-server
#
# Nothing here touches the working tree or any branch. The build is
# deterministic for a given (upstream main + patch pair): re-run it any time.
#
# RUNBOOK: docs/BUILD_PATCHES.md — the safety behaviors, how to update a
# patch, what to do when upstream main moves, and how to swap the live
# server. Read it before changing patches/ or this script.
#
# Patches (in ./patches/):
#   0001-responses-accept-nonterminal-status.patch
#       Responses replay: accept non-terminal item status, drop unknown
#       item types (the "400 API" fix; upstream commit 10e2a71 on the
#       fix/responses-replay-status-tolerance branch).
#   0002-responses-heal-forked-checkpoint.patch
#       Responses fork-heal in the miss path (PR antirez/ds4#1194,
#       pr/responses-fork-heal).
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
# If upstream main has moved and a patch no longer applies, the build STOPS
# with the patch name and a `git apply --check` diff — resolve the conflict
# deliberately (rebase the patch onto the new upstream) rather than letting
# a half-applied tree build.

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

apply() {
    local p="$1"
    local abs; abs=$(cd "$(dirname "$0")" && pwd)/${p}
    if ! git -C "${WT}" apply --check "${abs}" 2>/tmp/ds4-build-apply.err; then
        echo "" >&2
        echo "PATCH DOES NOT APPLY on upstream ${FRESH}: ${p}" >&2
        echo "(upstream has moved; rebase the patch onto the new main, or pin with REF=<old-sha>)" >&2
        sed -n '1,40p' /tmp/ds4-build-apply.err >&2
        exit 1
    fi
    git -C "${WT}" apply -v "${abs}"
}
echo "applying patches ..."
apply patches/0001-responses-accept-nonterminal-status.patch
apply patches/0002-responses-heal-forked-checkpoint.patch

# --- 3. Build in the worktree ---
echo "building ds4-server ..."
make -C "${WT}" -j"$(sysctl -n hw.ncpu)" CC=/usr/bin/clang ds4-server

# --- 4. Install the binary over ./ds4-server (run scripts exec ./ds4-server) ---
cp "${WT}/ds4-server" ./ds4-server
chmod +x ./ds4-server
echo "done: ./ds4-server built from upstream ${FRESH} + 2 patches"
echo "run:  ./start-qwen38-longctx.sh   (runbook: docs/BUILD_PATCHES.md)"
