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
#   0007-responses-fork-guard-visible-keys.patch
#       Narrow the 0002 fork guard to visible-keyed checkpoints, on both the
#       load side and the store side. A token-text payload is byte-verified
#       against the incoming prompt by the loader (ds4_kvstore.c
#       try_load_text), so the token-id compare there is not evidence of a
#       fork: the loader rebuilds the prompt from the stored token history
#       plus the tokenized suffix, so ids differ at every earlier splice
#       boundary while the bytes are the same history. The compare therefore
#       discarded long spliced checkpoints and accepted short freshly
#       tokenized ones — inverted. On a single-slot server every client
#       switch took that path, so the heal never converged. Store side: the
#       departing checkpoint is persisted when its key is token-text, and
#       skipped only when a visible key would hide the fork. Measured need
#       (2026-10-29, this box, two pi clients, one resident session):
#       19:10:15 discarded a 294912-token payload (loaded=294912
#       common=243669) and re-prefilled 307066 tokens in 436.664 s, against
#       4.459 s for the same class of switch at 19:19:23. Multi-client
#       serving itself is --batched-session N (docs/SERVER.md:58, and the
#       reuse-aware router job_slot_score); this patch keeps the disk tier
#       usable on the way there and for N+1 clients.
#   0008-kv-discard-reason-per-decision-site.patch
#       kv_cache_discard_failed_disk_entry -> kv_cache_discard_disk_entry with
#       a reason argument, so the three decision sites stop sharing one label.
#       "forked-payload" is a deliberate policy discard of a checkpoint that is
#       valid for its own owner; "cold-prefix-sync-failed" / "prompt-sync-
#       failed" are engine errors; "cancelled-during-*" is a client that
#       stopped reading. Measured confusion: 2026-10-29 19:19:22 printed
#       reason=prefill-failed for a cancelled 140796-token prefill whose only
#       effect was deleting the payload it had loaded — read as corruption.
#       Diagnostic only: same unlink, same session invalidation.
#   0009-kv-tail-pool-sizes-with-resident-sessions.patch
#       Size the near-tail (supplementary) pool by resident sessions instead
#       of by server: cap 16 GiB -> 16 GiB x sessions, entry limit 2 -> 2 x
#       sessions, driven by a new ds4_kvstore.resident_sessions set from
#       slot_count after kv_cache_open. 0 is read as 1, so a single-session
#       box is byte-for-byte the old policy and tests/test_kvstore_near_tail
#       still passes unchanged. Measured need: a 393k checkpoint is ~12.3 GiB
#       (KV_PROFILE_ISOLATION.md §5), so the old 16 GiB ceiling could never
#       hold two clients' frontiers at any --kv-disk-space-mb — 240 GiB still
#       yields min(30, 16) = 16 GiB. Deviation from "local patches touch
#       ds4_server.c only": the sizing lives in ds4_kvstore.c, so the knob
#       must live there too (4 files, 38 insertions). Extends
#       tests/test_kvstore_near_tail with the policy cases (sessions unset =
#       16 GiB at a 240 GiB budget, 2 sessions = 30 GiB, 3 and 8 sessions =
#       30 GiB because the eighth-of-budget share binds), so the new branch is
#       proven rather than asserted in prose.
#   0010-kvstore-test-stub-payload-bytes.patch
#       A6's model-free test (tests/test_qwen_tool_disk_key.c) does not link once
#       A4 is in the tree: A4 made ds4_kvstore.c call ds4_session_payload_bytes,
#       which lives in ds4.c, and that target links only the store plus rax.
#       A4 ships the same stub in its own test; A6 needs one too. Diagnostic value
#       is nil and the near-tail branch is not what that fixture exercises, so the
#       value only has to be plausible. Found 2026-10-31: verification step 3 ran
#       only ds4_test --server, so this target had never been run in our contract.
#       NOTE: with the stub it links and then fails 8 rows, because A2 (PR #1169)
#       and A6 (PR #1212) changed the same key-and-suffix rule from opposite sides
#       and upstream never ran them together. That red is documented in
#       docs/BUILD_PATCHES.md and is NOT this patch's concern.
#   0011-responses-cancel-remember-visible.patch
#       An interrupted Responses turn cleared every live handle, so the next
#       request (the escape-and-continue message) reused nothing: routing
#       evicted a resident checkpoint and the whole prompt re-prefilled
#       (observed 2026-10-31 19:48: 201,688 tokens, 229 s, for a conversation
#       31 tokens from its frontier). The visible tier also cannot fire after
#       an abort even without the clear: the handle sits at the last
#       completed-turn boundary and the tier demands live_tokens == live_pos.
#       On the cancel branches, remember the visible surface at the CURRENT
#       frontier via the same turn-end builder (strict equality then holds;
#       no KV rewind is needed - rewind is GLM-only), and log the cancel -
#       those branches were silent, which is why the Oct-17 and Oct-31
#       disconnect lines were "missing". A client that replays bytes the
#       server never streamed, or drops the aborted turn, misses exactly as
#       before: a safe miss, never a wrong reuse. Tests: probe case 8 +
#       test_responses_cancel_release_live.
#   0012-kv-fork-next-shorter-candidate.patch
#       A forked visible-keyed disk payload ended the disk tier and the turn
#       re-prefilled from token zero. The 0007 discard stays (protective),
#       but the turn now retries the lookup: the refresh inside the lookup
#       rescans the store directory, so the discarded file is never offered
#       again and the next-shorter text-prefix candidate gets its own
#       lockstep check. A pre-fork ladder checkpoint is token-exact by
#       construction and loads; recovery costs prompt-minus-frontier instead
#       of the whole prompt (observed shape: 172k rejected above 65k ladder
#       files; full 229 s prefill becomes ~154 s). Bounded at 4 attempts.
#       Live-smoke-verified (model-free unit coverage is the refresh-rescan
#       behavior the loop depends on; precedent: 0007 shipped the same way).
#   0013-responses-cancel-remember-partial-visible.patch
#       Scope fix for 0011: the escape path does not reach the branches 0011
#       instruments. generate_job_inner has SEVEN request_live_state_clear()
#       sites under job_cancelled, and an interrupted decode returns at the
#       first one after the decode loop ("cancelled during generation after
#       N tokens"), which 0011 left as a silent clear - so 0011's log line can
#       never appear for an escape, and the 2026-11-01 23:14/23:18 recoveries
#       came from the disk and memory-token tiers, not from 0011. That branch
#       also cannot reuse 0011's helper: the completed-turn builder closes the
#       surface with the model's end-of-turn marker, and a cancelled turn never
#       commits that token (the decode path skips it under cancel), so the
#       handle would claim one token more than the live KV holds - wrong reuse,
#       not the safe miss the tier contract demands. This patch remembers a
#       PARTIAL surface instead: prompt text + reasoning-so-far, or prompt text
#       + content-so-far, with no marker appended, so the next request
#       re-tokenizes the boundary and end-of-turn tokens onto the live KV. Only
#       a single-surface partial qualifies (a partial with both needs the
#       boundary marker between them; a partial that reached a tool call needs
#       the call markup), and everything else keeps the pre-fix clear. The
#       parser is asked without the closed-thinking requirement, because the
#       cancelled turn is unclosed by definition. Test:
#       test_responses_cancel_release_live_partial (mutation-checked: breaking
#       the surface-length assertion turns the suite red).
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
apply patches/0007-responses-fork-guard-visible-keys.patch
apply patches/0008-kv-discard-reason-per-decision-site.patch
apply patches/0009-kv-tail-pool-sizes-with-resident-sessions.patch
apply patches/0010-kvstore-test-stub-payload-bytes.patch
apply patches/0011-responses-cancel-remember-visible.patch
apply patches/0012-kv-fork-next-shorter-candidate.patch
apply patches/0013-responses-cancel-remember-partial-visible.patch

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
echo "done: ./ds4-server built from upstream ${FRESH} + 8 upstream PR patches + 11 local patches"
echo "run:  ./start-qwen38-longctx.sh   (runbook: docs/BUILD_PATCHES.md)"
