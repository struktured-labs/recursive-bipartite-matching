# MCCFR Index Redesign — Post-Verifier Honest Plan

_2026-06-03. Distilled from the `mmap-research-2026-06-03/` bundle after
3 adversarial verifiers stress-tested the synthesis._

## What survived verifier review

### Solid, low-risk wins (ship these first)

1. **Per-layer u32 fingerprints at MPHF slots** — eliminates the "unknown
   key returns a garbage slot" hazard at zero extra hashes, FPR ≈ 2^-32.
   Strictly dominates Bloom filter at shallow LSM layers.
2. **`arc-swap` for atomic layer-stack publish** — clean RCU pattern,
   readers never block during freeze.
3. **Custom Rust LSM with size-tiered fanout 4** — beats general-purpose KV
   stores (LMDB, RocksDB, redb, sled all rejected). We don't pay for ACID,
   range queries, transactions, or compression we'll never use.
4. **Hugepages (2 MiB only, not 1 GiB) + `MADV_HUGEPAGE` + `MADV_RANDOM`**.
5. **Total-RBP-style pruning during freeze** (Libratus's biggest single
   space-saver per the prior-art research). Drops entries with very
   negative regret + low strategy sum.

### Rejected (firmly)

- LMDB / RocksDB / redb / sled / odht as primary — storage budget alone
  disqualifies B+tree designs at 10B scale; LSM general-purpose stores
  pay for features we don't use.
- libcuckoo / abseil / F14 / Folly FFI — `hashbrown` is already at C++
  parity for u64 keys.
- Robin Hood hashing, HAMT, sorted array + binary search, FST.
- Bloom filter at shallow layers (fingerprint dominates).
- Leveled compaction (RocksDB-style).
- Learned indices (hashed keys have uniform CDF — nothing to learn).

## What the verifiers broke

### Showstoppers (must redesign before coding)

**S1. "left-right + arc-swap on per-thread FxHashMap" is incoherent.**
- `left-right` (Ramalhete) and `arc-swap` (RCU) are different primitives;
  the synthesis conflated them.
- L0 is per-thread today — there's no cross-thread reader to be wait-free for.
- `FxHashMap` mutation requires `&mut`; a reader holding `&` via Arc while
  the owning thread mutates is **immediate UB**, not "racy but mostly fine."

  **Fix**: keep L0 per-thread. Freeze copies the snapshot under owning
  thread's `&mut`, then publishes the resulting *frozen layer* (not the
  hot map) via `ArcSwap<LayerStack>`. Drop the "left-right" framing.

**S2. `crossbeam-epoch` deferred munmap can't see that a reader holds
  an offset into an old arena segment.**
- Reader's `Guard` pin only tracks "this thread is inside a critical
  section" w.r.t. the structure it entered with. Carrying a `u64 offset`
  to a different generation's arena escapes the guard.
- Fix: bundle the arena `Arc` directly into the resolved entry, so
  the regret-load lifetime is tied to the same arena handle that produced
  the offset. Or extend the read critical section to cover the arena
  dereference too.

### Significant overclaims to correct

**O1. PtrHash is not a clear storage win over our existing `ph::fmph::GOFunction`.**
The synthesis claimed "migrate from boomphf" — we don't use boomphf.
Our existing `ph::fmph::GOFunction` is 2.1 bits/key; PtrHash is 2.4 bits/key.
**PtrHash is bigger, not smaller.** PtrHash's actual selling point is
query speed (8.7 ns warm streaming, 12 ns serial). If we adopt it we
should benchmark on our actual workload first.

Also: PtrHash's `epserde` feature pulls in `mmap-rs` as a transitive
dep, which is a different crate from the `memmap2` we already use.
Adoption requires either both coexisting or a `memmap2` → `mmap-rs`
migration.

**O2. The "100-150 ns cold" lookup is handwave.**
DDR5 random access uncontended is ~80-100 ns. With 32 threads contending
8 channels, queueing pushes single-miss latency to 120-160 ns.
**3 cache misses cold = 240-480 ns realistic**, not 100-150 ns.

**O3. The "stride-aligned" framing on the 16 B payload is misleading.**
MPHF scatters keys uniformly; access is random. The 16 B packing helps
only because it fits in a single cache line — not because of striding.

**O4. The 8-lookup batched prefetch breaks on MCCFR dependency chains.**
Action chosen at depth N depends on regrets read at depth N-1. Can't
prefetch all 8 in parallel without restructuring traversal. Either:
- Enumerate all info-set keys for the trajectory up front in a tree walk,
  then prefetch — major refactor of `traversal::mccfr_traverse`
- Keep serial and accept the 3-5× speedup claim collapses

**O5. 154 GB total ≠ 120 GB working set.**
The hard constraint is 120 GB **working set**, not total on-disk. Page
cache for a uniform-hash index has no temporal locality — by construction
the access distribution into MPHF slots is uniform. Temporal locality
lives in the hot tier only. Treating page cache as a working-set
reducer for the frozen tier is wrong.

**O6. `xorf` doesn't implement ribbon filters.**
It provides Xor8/16/32 and BinaryFuse8/16/32. Binary Fuse is similar
(~9 bits/key for BinaryFuse8) but not ribbon. No maintained Rust ribbon
crate exists — port or use Binary Fuse.

**O7. `libnuma` Rust binding is dead since 2017.**
For `set_mempolicy(MPOL_INTERLEAVE)` either write a ~50 LOC syscall
wrapper ourselves or shell out to `numactl` at process launch.

## Honest plan after corrections

### Phase 1 — Fingerprint at existing MPHF slots (2-3 days, low risk)
- Add `u32 fingerprint[]` array alongside existing `ph::fmph::GOFunction`
  + payload arrays on each frozen layer.
- On lookup: `fingerprint[slot] == hash32(key)` → mismatch means absent.
- **Memory delta**: +4 B/key on frozen layers (+1-4 GB at 250M-1B scale).
- **Independently shippable.** Validates the file-format-extension path
  without changing data structures.

### Phase 2 — Benchmark PtrHash vs `ph::fmph::GOFunction` (1 week, low risk)
- Standalone bench: build a 100M-key MPHF with both, measure lookup
  latency on actual EPYC hardware and storage cost on real key
  distribution.
- **Decision gate**: adopt PtrHash only if measured query speed wins
  outweigh the 0.3 bits/key storage cost AND the `epserde` /
  `mmap-rs` dep conflict.
- **Risk if we adopt**: dep tree change. **Risk if we don't**: phase 5
  may not hit the latency budget.

### Phase 3 — Total-RBP pruning during freeze (3-5 days, low-medium risk)
- During L0 → L1 compaction, drop entries where `max(|regret|) < ε_prune
  AND strategy_sum < ε_thresh`.
- Validate that we're not dropping load-bearing entries via a Slumbot-eval
  comparison at 1B scale (with vs without pruning).
- **Memory delta**: ~30% trim on frozen layers per Libratus reports.

### Phase 4 — Hot-tier snapshot freeze + `arc-swap` layer publish (1 week, medium risk)
- Replace any current freeze synchronization with: owning thread takes
  exclusive `&mut` on its hot map, copies into the new frozen layer
  (with PtrHash or existing fmph), then publishes via
  `ArcSwap<LayerStack>`.
- Drop the broken "left-right + arc-swap" framing from the synthesis.
- Concurrency stress test: 1M lookups/sec across 32 threads during a
  synthetic freeze; assert no missing keys, no UB, no segfaults.

### Phase 5 — Per-generation arena segments + bundled lifetime (2 weeks, high risk)
- Switch f32 arenas from one-file-grows-forever to one-arena-per-generation.
- Each resolved `CompactEntry` carries the arena `Arc` it belongs to;
  reclamation only fires after all entries pinning that generation
  drop their handles. **Do not** rely on `crossbeam-epoch` for this.
- 24-hour fuzz test with poison bytes on reclaimed pages.

### Phase 6 — Hugepages + MADV + NUMA + (maybe) batched prefetch (1 week, low-medium risk)
- `MADV_HUGEPAGE` + `MADV_RANDOM` on payload arenas; `mlock` deepest
  layer's ctrl/fingerprint arrays.
- 50 LOC `set_mempolicy(MPOL_INTERLEAVE)` wrapper at startup before
  rayon pool spawn.
- Defer batched-prefetch until O4 is resolved by either accepting the
  serial path or restructuring traversal.

## Total realistic effort

**5-7 weeks of focused work** (matches initial estimate). Phase 1 alone
makes the 1B-scale safer immediately and is the right first PR.

Phase 2's benchmark may invalidate Phase 4's PtrHash assumption — that's
fine, it's a decision gate by design. Phases 3-5 are independent enough
to interleave if needed.

## Open questions still requiring decisions

1. PtrHash vs `ph::fmph::GOFunction` benchmark winner (Phase 2 gate)
2. Fingerprint width: u32 (default) vs u64 (zero FPR) — measure spurious
   rate at 1B before committing to u64
3. Whether to restructure `traversal::mccfr_traverse` to support batched
   prefetch (O4) — defer until Phase 5 perf numbers show it's needed
4. NUMA topology details on the new Hostkey 7402P box (Phase 6 deferred
   until we have hardware)

## Cross-references

- Full research bundle: `mmap-research-2026-06-03/`
- Original synthesis (with bugs): `mmap-research-2026-06-03/00_SYNTHESIS.md`
- Verifier reports: `mmap-research-2026-06-03/02_verify_*.md`
