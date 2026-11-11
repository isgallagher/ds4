# ds4 — one kv-cache directory per rope profile

> [!important] The rule
> **Give each rope scaling its own `--kv-disk-dir`.** Rope scaling, not context
> length, is the property a KV checkpoint cannot declare. Today the two profiles
> on this box (`262k` with YaRN off, `393k` with `DS4_QWEN4_YARN_FACTOR=1.5`)
> share `~/.ds4/kv-cache`, and that is safe only by accident.

Status: **recommendation, not yet applied** (owner decision pending, 2026-10-16).
Nothing in this file has been built or deployed. All evidence below was measured
or read on this box on 2026-10-16.

**Line numbers are from the deployed tree** = upstream `fc80bd6` + the patch set
in `build.sh`. That tree is not the working tree — see
`BUILD_PATCHES.md` § Do-not list. Re-create it for reading with:

```bash
R=$(pwd); git worktree add --detach /tmp/ds4-read fc80bd6
for p in <the build.sh patch list, in order>; do
    git -C /tmp/ds4-read apply "$R/$p" || git -C /tmp/ds4-read apply -3 "$R/$p"
    git -C /tmp/ds4-read add -A && git -C /tmp/ds4-read commit -q -m "apply $p"
done
```

The commit between steps is not cosmetic: the 3-way fallback needs an index that
matches HEAD, and without it `pr1169` and `pr1212` fail to apply.

---

## 1. What a checkpoint records — and what it cannot

The 48-byte header (`ds4_kvstore.c:394-417`, `ds4_kvstore_fill_header`) holds:

| bytes | field |
|-------|-------|
| 0-3 | magic + `KV_CACHE_VERSION` |
| 4-7 | quant bits, reason, ext flags, **model id** |
| 8, 12, 16 | tokens, hits, **ctx_size** |
| 20 | `KV_CACHE_PAYLOAD_ABI` |
| 24, 32 | created_at, last_used |
| 40 | payload_bytes |
| 48 (after header) | text_bytes |

The file **name** is the SHA-1 of the stored rendered text, and the lookup
compares that hash against hashes of the incoming prompt's prefixes
(`ds4_kvstore_find_text_prefix`, `ds4_kvstore.c:1396`; entry comment in
`ds4_kvstore.h`).

**There is no rope field, and no spare byte to put one in.** A word-boundary
search for `rope`, `yarn`, `rotary`, `mscale` across `ds4_server.c` and
`ds4_kvstore.c` returns zero hits: nothing in the server or the store path knows
the setting exists.

## 2. Why the setting changes the payload

`qwen4_rope_configure` (`ds4.c:6976-7002`) reads `DS4_QWEN4_YARN_FACTOR` and,
when the factor is above 1.0, rescales the rotary inverse frequencies **for all
positions** and changes `mscale`. It is not a beyond-262k-only adjustment.

Consequence: a stored checkpoint holds K vectors rotated under the boot-time
scaling. A session booted with a different factor computes the continuation in a
different rotary frame. Reusing that prefix is silently wrong — nothing errors,
the attention scores are simply computed against mismatched rotations.

## 3. Why `ctx_size` is not a guard

The lookup filter is one-directional (`ds4_kvstore.c:1408`):

```c
if ((uint32_t)ctx_size < e->ctx_size) continue;
```

- A 262k session **cannot** load a 393k checkpoint. That direction is blocked.
- A 393k session **can** load a 262k checkpoint. That direction is open, and it
  is the direction a move to the long-context profile walks through.

The proxy also fails at equal context. YaRN is an independent env knob, so
`--ctx 393216` with factor 1.5 and with factor 1.2 produce entries with
**identical headers** and different rotations. Nothing can distinguish them.

The two regimes are separated today only because the launchers happen to pair
`ctx 393216` with `YARN=1.5` and `ctx 262144` with no YaRN. A convention that
lives in a shell script is not a guard.

## 4. Recommended layout

| profile | flags | directory | launcher |
|---------|-------|-----------|----------|
| 262k + vision (daily driver today) | ctx 262144, no YaRN | `~/.ds4/kv-cache-262k` | `start-qwen38-262k-vision.sh` |
| 262k + vision, N resident sessions | ctx 262144, no YaRN, `--batched-session N` | same as above, **deliberately** — identical rope frame, so checkpoints carry over instead of being rebuilt | `start-qwen38-batched-vision.sh` |
| 393k long-context (max thinking) | ctx 393216, `DS4_QWEN4_YARN_FACTOR=1.5` | `~/.ds4/kv-cache-393k` | `start-qwen38-longctx.sh` |
| 393k, N resident sessions | ctx 393216, YaRN 1.5, `--batched-session N` | must **never** share a directory with a native-frame profile | `start-qwen38-batched.sh` |

> [!warning] The directory names above are the recommendation, not the field state
> Both the 262k vision profile and the 393k YaRN profile are launched today against the **same** `~/.ds4/kv-cache`, which is exactly the mixing §1–§3 warn about. The batched-vision launcher shares it on purpose (same frame); the YaRN launcher warns on every start and refuses a YaRN factor at native context. The rename below is still the correct fix and is still not done.

> [!tip] Watch for a context/cold-path mismatch
> The live 2026-10-31 invocation carried `--kv-cache-cold-max-tokens 393216` against `--ctx 262144` — a leftover from the YaRN profile that asks the cold path for checkpoints wider than the context can hold. The batched launchers derive the value from `CTX` so it cannot drift.

- Rename the current store to `~/.ds4/kv-cache-262k` **while the server is
  stopped** — the live store holds those paths. Do not delete it: it holds
  recoverable frontiers.
- The store directory is created recursively when missing (`kv_mkdir_p`
  `ds4_kvstore.c:356`, called at 628), so the 393k profile needs no prep.
- Budgets are per store instance (`ds4_kvstore.c:637`), so each profile gets its
  own `--kv-disk-space-mb` **and** its own near-tail allowance.
  `kv_cache_tail_budget` = `min(budget/8, 16 GiB × resident sessions)` — per
  **session**, not per server, since our patch `0009`: a
  checkpoint is a frontier for one conversation, so N resident sessions need room
  for N of them. `resident_sessions` is set from the server's slot count, so the
  pool cannot drift from `--batched-session`, and `0` is read as `1` so a
  single-session box keeps the original figures exactly. Arithmetic that matters:
  a 393k checkpoint is ~12.3 GiB (§5), so at 120 GiB the pool is
  `min(15, 32) = 15 GiB` and holds **one**; at 240 GiB with two sessions it is
  `min(30, 32) = 30 GiB` and holds **two**. The eighth-of-budget share, not the
  per-session cap, is what an operator buys with disk budget.
- The near-tail prune is global and keeps `2 × resident sessions` entries with no
  conversation check
  (`kv_cache_tail_prune`, `ds4_kvstore.c:994-1029`). Separate directories stop
  the 393k profile's ~12 GiB checkpoints from evicting the 262k profile's small
  ones. Measured in the field on 2026-10-16: one session's 25,527-token store
  evicted another session's 70,190-token checkpoint, which was the checkpoint
  that session had just rebuilt from.
- Space is not the constraint: 615 GiB available on a 1.8 TiB volume, store at
  59 GiB across 20 files (measured 2026-10-16 22:5x). Two 120 GiB budgets fit.

## 5. What the 393k profile costs, per checkpoint

Measured on this box (Q4, Metal, chunk 8192):

- **Prefill: 505-991 tok/s** (15,786 tokens in 27.667 s = 571 tok/s) → about
  2 ms of recovery per token.
- **A checkpoint is about 32 KiB per token** (4,687 MiB at 150,757 tokens;
  6,514 MiB at 196,608 tokens).
- **A store takes 7.4-9.2 µs per token** (1,112 ms at 150,757; 236 ms at 25,527).
- At **393,216 tokens that is about 12.3 GiB and about 3.6 s per checkpoint**,
  and the 15 GiB near-tail budget fits **exactly one** such entry.

This is why `--prefill-chunk` is the wrong lever for checkpoint density: that
flag is also the prefill batch cap (`ds4_prefill_cap_for_prompt` `ds4.c:14303`,
applied per session at `ds4.c:74024`), so lowering it slows every rebuild by the
same factor it increases store frequency.

## 6. Verifying a profile after the switch

- **Rope:** the server prints its YaRN configuration to stderr **only when YaRN
  is active** (`ds4.c:7002`). Grep the profile's log after launch: the line's
  presence proves which scaling actually booted.
- **Binary and flags:** verify by artifact, not by `pgrep` pattern — match
  `lsof` device:inode and the sha256 of the running text against the installed
  file, and read the flags from argv. Procedure: `BUILD_PATCHES.md`
  § Swapping the live server onto a fresh build.
- **Expect one full rebuild** on the first request of a new profile. That is the
  cost of an empty store, not a regression.

## 7. The fix that removes the convention (not written)

**Salt the checkpoint key with the rope setting.** The filename is already the
SHA-1 of the stored text, and the lookup hashes prompt prefixes with the same
routine. Fold the rope factor into the hashed bytes and entries from different
scalings become structurally unable to match each other.

- No header format change, no version bump, no new flag to remember.
- Cost: every existing filename changes, so the store starts empty once. It is a
  cache; that is acceptable.
- Sites: the store-side hash write and `ds4_kvstore_find_text_prefix`
  (`ds4_kvstore.c:1396`).

This is strictly better than the directory rule because the code enforces it.
Until it exists, the directories are the only isolation available.

## 8. Related open findings (do not re-derive)

- **Vision requests write no checkpoint at all.** All three store paths are
  gated on `!multimodal`, where `multimodal = j->req.image_count != 0`
  (`ds4_server.c:13872`; gates at `14372`, `14382`, `14390`, `14513`; near-tail
  also checks `req->image_count` at `11614`). A client that replays images in
  history therefore stops writing checkpoints from the first image onward.
- **The interval store is an equality test.**
  `ds4_kvstore_continued_store_target` (`ds4_kvstore.c:769-776`) returns 0 unless
  `live_tokens % step == 0`. It fires only when decode walks across the exact
  multiple (`ds4_server.c:14513`); prompt growth jumps over it. Measured: one
  store across 93k tokens of agentic prompt growth.
- **Disk recovery ignores the divergence point.** Every load call site passes
  only the rendered prompt text (`kv_cache_try_load_text`, `ds4_server.c:11756`),
  so recovery distance is set by what was stored, never by where the two
  histories diverged. A 40,610-token re-prefill on 2026-10-16 traced to exactly
  this.
