I have enough verified data. The task is one-shot research; the existing task list belongs to the training rollout, not this gut-check. Returning the verdict-per-claim table directly.

---

# Gut-Check: MCCFR Index Architecture Proposal

## Verdict-per-claim table

| # | Claim | Verdict | Evidence / objection |
|---|---|---|---|
| **A. Lookup-cycle / cache-line accounting** | | | |
| A1 | Hot SwissTable warm lookup ~30 ns, 1-2 cache lines | **PLAUSIBLE** | hashbrown/SwissTable is SIMD-batched ctrl probe → typical published numbers are 8-30 ns warm. Group probe is 1 ctrl-byte line + 1 slot line; the third line (key + value if slot straddles a line, or rehash to confirm) is omitted. For 32-byte SwissTable groups holding `(u64, CompactEntry)` slots at 16 B = 2 slots/line: probe + slot can straddle. Realistic: 1-3 lines. The "~30 ns" is reasonable as a sample mean, not a worst case. |
| A2 | PtrHash frozen-layer probe = 1-2 cache lines for MPHF, ~8.7 ns warm | **VERIFIED-with-caveat** | PtrHash paper reports 8 ns/key streaming, 12 ns/key serial on 10⁹ integer keys, at 2.6 GHz on an i7-10750H with 64 GiB DDR4-3200. Your EPYC has 8-channel DDR5 — *faster* memory, but no specific PtrHash EPYC numbers exist. The "8.7 ns" is essentially the streaming-bench number. **The proposal silently uses the streaming number in a context where it claims serial-style "~30 ns warm".** Reconcile: serial PtrHash is 12 ns, streaming 8 ns. |
| A3 | "~3 cache misses cold, ~100-150 ns cold, ~30 ns warm" for frozen layer | **HANDWAVE** | The arithmetic doesn't pencil out. Random DRAM access on DDR5-4800 is ~80-100 ns *uncontended*; with 32 threads hammering 8 channels, queueing pushes it to 120-160 ns/miss. 3 misses cold = 240-480 ns realistic, not 100-150. The proposal is anchoring to single-thread microbench numbers from a 4-channel DDR4 desktop and projecting onto a 32-thread DDR5 server with 8x more contention. |
| A4 | "16 B/key payload, stride-aligned cache-line packing" | **WRONG** | 16 B/key with random MPHF slot order means every payload load is a fresh cache miss — the "stride-aligned" framing is misleading because the access pattern is random. The 16 B packing helps fanout-of-line-touches only if multiple lookups hit adjacent slots, which they won't (MPHF scatters keys uniformly). The reality: payload = 1 unconditional cache miss per lookup. Not "stride-aligned"; just "single line per access by luck of packing." |
| A5 | u32 fingerprint check is "1 cache line cost (zero extra hashes)" | **PLAUSIBLE-but-not-free** | If the fingerprint array is laid out separately from the payload, that's a 2nd cache miss per probe. The proposal's "11 B payload padded to 16 B" implies fingerprint lives elsewhere. If fingerprint+payload are interleaved into a single 16-byte slot, OK — but then the slot is `[u32 fp][u64 off][u8 na][u16 ep]` = 15 B → 16 B padded, single line, that's fine. The proposal is ambiguous; verify which layout was meant. |
| A6 | Batched 8-lookup prefetch → 150-250 ns total, 3-5× speedup | **PLAUSIBLE** | This is the textbook prefetch-pipeline trick and PtrHash's streaming mode explicitly does it (32-ahead). 3-5x is in the documented range for hashmap batches. **Caveat**: the 8 lookups per MCCFR iter are not independent — the action chosen at depth N depends on the regret read at depth N-1. You cannot prefetch all 8 in advance unless the action-selection logic is restructured (e.g., enumerate all 8 info-set keys for the trajectory up-front via a tree walk, then prefetch). The proposal doesn't mention this restructuring. **If kept serial, the prefetch claim collapses.** |
| **B. Memory budgets** | | | |
| B1 | 15.4 B/key total → 154 GB at 10B entries | **PLAUSIBLE** | 2.4 bpk MPHF + 4 B fp + 11 B padded to 16 B payload ≈ 16.3 B raw → 163 GB. Close enough. **But omitted**: per-layer file headers, page-aligned slack at layer boundaries (~2 MiB each × hundreds of layers if not compacted aggressively), the 4-bit ribbon on L3/L4 (~5 GB), epserde container overhead. Realistic ceiling 170-185 GB on disk, not 154 GB. |
| B2 | "Hits the <120 GB working-set budget" | **WRONG** | The hard constraint says "10B aspirational needs <120 GB **working set**". 154 GB total is not 120 GB working set. The proposal then waves at "page cache handles wide tail" — but page cache for a *uniform-hash* index has no tail. By construction the access distribution into MPHF slots is uniform. Temporal locality lives in the *hot tier*, not the frozen tier. Treating the OS LRU as a "free 50% reduction" on a uniform-access frozen tier is the kind of optimism that kills systems. **Either (a) the frozen tier resident set is in fact ~150 GB and we need 256 GB box, or (b) we pay disk faults on every cold tail access.** |
| B3 | Hot tier 160 MB/thread × 32 = 5 GB | **PLAUSIBLE** | 10M entries × ~48 B/SwissTable-entry × 1.5 load factor → ~720 MB/thread (not 160 MB). The "48 bytes/key" figure is already cited in `frozen_state.rs`. So 32 threads × ~720 MB = **~23 GB**, not 5 GB. The proposal undercounts hot tier by ~5x. **For left-right (2x duplication during freeze): ~46 GB transient.** |
| B4 | Compaction transient ~10-20% | **HANDWAVE** | Arena-per-generation means the new generation must hold the *survivors* of the merged layers before the old is unmapped. At fanout 4, merging L0+L1 = 50M entries × 16 B = 800 MB transient. Larger merges of L3 (640M) → 10 GB transient. The 10-20% is plausible *for the index* but not specified for the *arenas*, which are far larger (f32 regret + strategy × N actions). Arena transient could be tens of GB. The proposal hand-waves without bounding. |
| B5 | mlock'd ctrl+fingerprint of L4 "~10 GB" | **WRONG arithmetic** | L4 is "2.5B+ entries" at 4 B/fp + ~0.3 B/ctrl = ~11 GB just fingerprints + ~750 MB ctrl. At 10B aspirational scale, L4 holds essentially all of them → 40+ GB fp + 3 GB ctrl. The "10 GB" assumes 2.5B but you said "L4 = 2.5B+ at fanout 4 ... max ~5 layers" — at 10B the structure needs another level or L4 is huge. Either way mlock at 10B scale is 40-50 GB, likely too much. |
| **C. mmap / page cache** | | | |
| C1 | OS page cache handles the wide tail via 2-list LRU | **WRONG-for-this-workload** | The 2-list LRU works when there *is* a hot subset. MCCFR has trajectory-level temporal locality (hot board buckets recur), but that locality lives at the **info-set key** level. After the MPHF scatters keys uniformly across the slot array, the *page* access pattern is uniform random. Unless the build process **slot-sorts entries by access frequency** (which the proposal does not), the page cache will fault on each cold access with no help from LRU. The 50% "working set fits" optimism rests on locality that the data structure actively destroys. |
| C2 | `MADV_HUGEPAGE` on all arenas | **PLAUSIBLE-with-stall-risk** | Confirmed by kernel docs. Stalls during compaction are well-documented (`defrag=madvise` mitigates, doesn't eliminate). The proposal acknowledges this. **However**: with 32 reader threads on uniform-random access, THP compaction stalls produce p99 spikes that *will* hit the "per-LOOKUP cache miss not OK" constraint. Set `defrag=defer` not just `madvise`. |
| C3 | `MAP_POPULATE` rejected as too slow | **VERIFIED** | Sound call. Touching 150 GB at boot = minutes. |
| **D. Per-iter latency at 32K lookups/sec aggregate** | | | |
| D1 | "32K lookups/sec aggregate at 32 threads" | **CORRECT but trivially low** | This is 1000 lookups/sec/thread, 1 µs budget per lookup. SwissTable warm fits this 30x over. **The number sandbags itself** — even a B+tree would fit this budget. The real constraint is the **8-lookup-per-iter sequential dependency** (D2). |
| D2 | "Per-iter cache miss OK; per-lookup not OK" honored | **HANDWAVE** | If the 8 lookups are truly sequential (each depends on the previous action), then they cannot be batched — proposal A6 is invalidated, and the "1 cold miss per layer × 5 layers × 8 lookups = 40 cold misses per iter" = 40 × ~140 ns = 5.6 µs per iter. At 4000 iters/sec/system that's 5.6 ms × 32 threads of sequential miss latency, but threads are parallel so per-iter wall time is 5.6 µs uncontended. Memory bandwidth is the bottleneck: 40 misses × 64 B × 4000 iters × 32 threads = ~328 GB/sec memory bandwidth required. **DDR5-4800 × 8 channels = ~307 GB/s peak**. You are *at or over* memory bandwidth ceiling at 10B scale. |
| D3 | Reader contention on arc-swap loads at 32K/sec | **PLAUSIBLE** | `arc-swap::load` is wait-free and the load rate is low. This won't bottleneck. |
| **E. Compaction stall claims** | | | |
| E1 | "Zero reader blocking during freeze" via left-right + arc-swap | **PLAUSIBLE-with-data-race-risk** | Architecturally sound. The danger is **referential integrity**: a reader holding an `Arc<LayerStack>` snapshot may resolve an entry whose arena offset belongs to a generation that's about to be reclaimed. `crossbeam-epoch` defers munmap, but you must pin the epoch for the *entire* lookup including arena read, not just the index probe. The proposal doesn't make this explicit. **High risk of TOCTOU bug.** |
| E2 | Compaction is background, reader-latency-flat | **HANDWAVE** | Background compaction competes for the same 307 GB/s memory bandwidth (D2). On a system already near bandwidth ceiling, compaction will *measurably* steal from reader throughput. Saying "readers don't block" is true on a lock-acquire sense and false on a bandwidth-share sense. Quantify before claiming. |
| **F. "Faster than the alternative" claims** | | | |
| F1 | "B+tree designs disqualified by storage budget" | **PARTIALLY VERIFIED** | LMDB/redb at 10B u64 keys with 16 B values do bloat to ~250+ GB with page overhead. Correct conclusion, suspicious magnitude — the proposal says "280+ GB" without showing the math. Approximately right. |
| F2 | "32-bit fingerprint strictly dominates Bloom" | **VERIFIED-for-this-tradeoff** | For MPHF + presence check, putting an in-line fp at the resolved slot is cheaper than a separate Bloom probe (which is its own cache miss). Confirmed pattern in modern LSMs. |
| F3 | "PtrHash 2× faster than BBHash" | **PLAUSIBLE** | PtrHash paper does claim 2.1× over competitors at similar bits/key. BBHash specifically isn't always the strawman in their bench. Verify against the specific BBHash variant (`fmph::GOFunction`) currently used in `compact_state.rs`. |
| F4 | "RocksDB mmap mode deprecated" | **PLAUSIBLE** | Facebook does recommend block-based table with buffered I/O. Not strictly "deprecated" but discouraged. Accurate-enough. |
| F5 | "odht last release 2021" → dependency risk | **VERIFIED** | rustc still uses it in production; vendoring 3K lines is fine. Sound reasoning. |
| F6 | "Robin Hood dirties extra mmap pages" | **PLAUSIBLE** | True architecturally. The actual write-amplification cost vs SwissTable's group-batching is small in practice; the case against Robin Hood is real but minor. |
| **G. Construction / build assumptions** | | | |
| G1 | "PtrHash construction stability at 1B+ keys" listed as open question | **CORRECT to flag** | The proposal honestly flags this. Construction on 1B keys: ~30 sec on i7-10750H per paper. EPYC should be faster. Stability concerns are legitimate for adversarial inputs but you have uniform u64 hashes so should be fine. |
| G2 | "epserde-serialized for zero-copy mmap" | **VERIFIED** | PtrHash docs confirm `epserde` feature for mmap. Adds dep weight (~5-8 crates transitively). |
| G3 | Construction memory overhead during freeze | **MISSING** | The proposal doesn't say how much RAM PtrHash build consumes for 1B keys. Paper implies a partition-based approach but doesn't quote peak RSS. Need to bench: a 30 GB transient RAM spike during freeze would invalidate the budget. |
| **H. Phase plan claims** | | | |
| H1 | "Phase 1 fingerprint = +4 B/key, +1-4 GB at 1B scale" | **CORRECT math** | 1B × 4 B = 4 GB. Fine. |
| H2 | "Phase 2 PtrHash saves 1-2 bits/key" | **PLAUSIBLE** | `fmph::GOFunction` is ~2.1 bpk per code comments; PtrHash is 2.4 bpk per paper. Wait — that's *worse*, not better. The proposal claims "smaller MPHF" but `fmph::GOFunction` (FMPHGO) is already at or below PtrHash bits/key. **The migration argument has to be speed, not space.** Re-justify. |
| H3 | "Phase 4 high blast radius" | **CORRECT to flag** | Honest. Good. |
| H4 | "~3-4K LOC total custom code" | **HANDWAVE** | Optimistic. LSM compaction logic + arena GC + epoch pinning across mmap regions is realistically 8-15K LOC in production-quality Rust. |

---

## Specific "WRONG" / "HANDWAVE" items requiring fix before commitment

1. **B2** (working set vs total): Either spec a 256 GB box explicitly, or design a hot-key resident substrate (e.g., LRU shadow index over the frozen layers).
2. **B3** (hot-tier sizing): Off by 4-5x. Real per-thread hot map is 700 MB-1 GB; 32 threads × left-right = ~46 GB transient. This *alone* is most of the "saved" budget.
3. **C1** (page cache LRU on uniform-MPHF access): Either accept ~150 GB resident, or build slot-sort-by-frequency in the freeze step. The current proposal silently relies on locality the structure destroys.
4. **D2** (memory bandwidth ceiling): At 10B scale with 5 layers and uniform-random access, the bandwidth requirement is at the DDR5-8ch ceiling. This is the **silent killer**. Build a synthetic bandwidth probe before committing.
5. **A6** (8-lookup batching): The MCCFR trajectory is sequential. Either restructure to pre-walk the info-set key list per iter, or drop the prefetch speedup.
6. **H2** (PtrHash motivation): Current `fmph::GOFunction` is already ~2.1 bpk; the migration story has to be query speed (12 ns vs current unknown), not storage. Bench the existing code first.

---

## What to benchmark before committing (in priority order)

1. **Bandwidth probe**: 32 threads × 5 sequential MPHF-style random cache-miss chains on actual EPYC box. Measure achieved GB/s and per-lookup p50/p99. If p99 > 1 µs, the architecture's premise breaks.
2. **Current `fmph::GOFunction` micro-bench**: Measure ns/lookup at 100M and 1B keys on the actual hardware. **Before** assuming PtrHash is the win.
3. **MCCFR per-iter trajectory restructure feasibility**: Can the 8 keys be enumerated up-front? If yes, prefetch is real. If no, drop A6 and recompute D2.
4. **Hot-tier memory footprint**: `cargo bench` with real key distribution — measure actual bytes/entry of `FxHashMap<u64, CompactEntry>` post-fill. Confirm or refute B3.
5. **Page-cache thrash test**: Synthetic 154 GB index on 128 GB RAM, 32 threads uniform-random read. Measure faults/sec and p99 latency. Decide 256 GB box vs slot-sort.
6. **PtrHash construction RAM at 1B keys**: Peak RSS during build. Confirm it doesn't eat the freeze-window budget.
7. **Left-right + arc-swap correctness**: 24-hour fuzz with synthetic freeze cycles, assert no stale arena offsets surface to readers.
8. **THP compaction stall under load**: Sustained 32-thread reader workload, measure p99 vs THP setting (`always` / `madvise` / `defer` / `never`).
9. **Compaction read-side bandwidth impact**: Run compaction alongside readers, measure read-throughput delta. Validate "zero blocking" claim quantitatively.
10. **End-to-end micro-prototype**: 100M-key version of full stack (Phase 1 fingerprint + PtrHash + left-right + ribbon prefilter) measured on the actual EPYC box, before committing to Phase 4's high-blast-radius arena-GC work.

---

## Summary judgement

The high-level architecture is sound. The **per-claim arithmetic is wrong or optimistic in 6-8 places**, mostly in directions that *understate cost*. The "10B in <120 GB" target survives only with one of: (a) a 256 GB box, (b) slot-sort-by-frequency, or (c) acceptance that frozen-tier access pays page-fault latency on a significant fraction of lookups. None of those are addressed honestly. The single biggest unaddressed risk is **D2: memory bandwidth ceiling at 10B scale**. Build the bandwidth probe before writing a line of LSM code.

Sources:
- [PtrHash paper (SEA 2025)](https://arxiv.org/abs/2502.15539)
- [PtrHash author's notes](https://curiouscoding.nl/posts/ptrhash/)
- [PtrHash repo](https://github.com/RagnarGrootKoerkamp/PtrHash)
- [arc-swap performance docs](https://docs.rs/arc-swap/latest/arc_swap/docs/performance/index.html)
- [xorf docs](https://docs.rs/xorf/latest/xorf/)
- [Linux page cache eviction](https://biriukov.dev/docs/page-cache/4-page-cache-eviction-and-page-reclaim/)
- [THP compaction stalls](https://loke.dev/blog/linux-thp-compaction-stall-performance)
- [hashbrown SwissTable](https://github.com/rust-lang/hashbrown)
- Codebase: `/home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/frozen_state.rs`, `compact_state.rs`, `Cargo.toml` (currently uses `ph::fmph::GOFunction`, not PtrHash)