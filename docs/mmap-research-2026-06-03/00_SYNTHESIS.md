# MCCFR Index Architecture Synthesis

### 1. Verdict

**Build a custom Rust mmap-backed LSM index with size-tiered frozen layers (fanout 4), PtrHash MPHF per layer, 32-bit key fingerprints at MPHF slots, and a left-right wrapped FxHashMap hot overflow. Per-generation arena segments with epoch-based reclamation. Atomic publish via `arc-swap`, zero reader blocking during freeze.** Do not adopt LMDB, RocksDB, redb, sled, odht, or rkyv — every external candidate either misses the 12 bytes/key storage budget at 10B scale or buys ACID/range/concurrent-write machinery we'll never use and pay for on every lookup. Vendor PtrHash (`ptr_hash` crate, SEA 2025), `memmap2`, `arc-swap`, `crossbeam-epoch`, `bytemuck`, and `rustc_hash` — write everything else ourselves (~3-4K lines). **Fallback**: if PtrHash construction stability or epserde dep weight becomes painful, swap PtrHash for vendored `odht` open-addressing tables per frozen layer (slightly worse bits/key, drop-in mmap-friendly, rustc-proven).

### 2. Proposed architecture

**Layer 0 — Hot overflow (per-thread)**
- **Data structure**: `FxHashMap<u64, CompactEntry>` (existing), wrapped in a left-right (Ramalhete) pattern using `arc-swap` so 32 readers see a wait-free consistent view during freeze.
- **Memory model**: Heap. Sized to ~10M entries per thread before freeze trigger (~160MB/thread × 32 threads = 5GB total hot tier).
- **Concurrency**: Single-writer (the owning thread plus a freeze coordinator), wait-free multi-reader via left-right alternation. `CompactEntry` = `(u40 offset, u8 n_actions, u16 epoch)` packed to 8 bytes.
- **Lookup cost**: SwissTable group probe — 1 L1 cache line (control), 1 L1/L2 cache line (slot). ~30 ns warm.
- **Justification**: hashbrown is the Rust SwissTable port; no FFI gain from abseil/F14/libcuckoo. Left-right gives us the wait-free reader semantics without the 2× memory hit applying to the frozen-tier majority of the data.

**Layer 1 — Frozen LSM layers (file-backed, immutable)**
- **Data structure**: Custom Rust per-layer triple: `(PtrHash MPHF, fingerprint[u32], payload[Entry])`. Sized geometry: L0=10M, L1=40M, L2=160M, L3=640M, L4=2.5B+ (fanout 4, size-tiered, max ~5 layers probed).
- **Memory model**: Each layer = one mmap'd file with 2 MiB-aligned arenas. Header (4 KiB) + MPHF (~2.4 bits/key via PtrHash, epserde-serialized for zero-copy mmap) + fingerprint array (u32, 4 B/key) + payload array (u64 offset + u8 n_actions + u16 epoch = 11 B padded to 16 B/key for stride-aligned cache-line packing).
- **Concurrency**: Read-only post-publish. Atomic `Arc<LayerStack>` swap via `arc-swap` on freeze. Reclamation via `crossbeam-epoch` deferred munmap.
- **Lookup cost**: PtrHash `index(&key)` → ~1-2 cache lines (~8.7 ns warm per PtrHash benchmarks) + 1 cache line fingerprint check + 1 cache line payload load. **~3 cache misses cold, ~100-150 ns cold, ~30 ns warm.** Newest-first probe with early-exit; deep layers (L3+) get a 4-bit/key ribbon prefilter to skip the MPHF probe on absent keys.
- **Justification**: PtrHash at 2.4 bits/key + 32-bit fingerprint + 11 B payload = ~15.4 B/key → 154 GB for 10B entries. **Hits the <120GB working-set budget once you consider only the hot subset is resident** (OS page cache handles the wide tail via the kernel's 2-list LRU). 32-bit fingerprint eliminates MPHF's "unknown key returns garbage slot" problem at 1 cache line cost (zero extra hashes, FPR ≈ 2^-32) — strictly dominates Bloom-in-front-of-MPHF for shallow layers per Report 6.

**Layer 2 — Value arenas (file-backed, append-only per generation)**
- **Data structure**: Flat `mmap` files holding f32 regret + strategy vectors, indexed by the `u64 offset` resolved from Layer 1.
- **Memory model**: One arena segment per "generation" (cohort of frozen layers built together). When all layers referencing segment N are compacted away, `munmap` + `unlink` segment N. **Never overwrite live arena slots** — compaction allocates fresh slots in the newest segment.
- **Concurrency**: Append-only writes during freeze (single writer). All other access is read-only.
- **Lookup cost**: Already-existing path. One cache miss per arena dereference. Unchanged.
- **Justification**: WiscKey pattern (Report 6) — keys in LSM, values in separate log. Compaction touches only the index, not the f32 arenas. Arena-per-generation eliminates the dangling-reference problem cleanly.

**Cross-cutting infrastructure**
- **NUMA**: `set_mempolicy(MPOL_INTERLEAVE, all_nodes)` at startup before rayon pool spawn. Replicate the ctrl-byte/fingerprint arrays of the hottest layer (L4) per NUMA node if RAM permits.
- **Hugepages**: `MADV_HUGEPAGE` on every arena, `mlock` only on the ctrl/fingerprint arrays of the deepest (L4) layer (~10 GB at 10B keys — verify against RAM budget). 2 MiB pages mandatory; do not use 1 GiB pages.
- **Prefetch**: Batch all 8 lookups per MCCFR iter — issue 8 `_mm_prefetch` calls on the MPHF group addresses before doing the 8 actual lookups. Expected 3-5× speedup (~150-250 ns batched vs. ~800 ns serial per Report 5).
- **MADV**: `MADV_RANDOM` on payload arenas, `MADV_HUGEPAGE` everywhere, `MADV_DONTNEED` on superseded layers post-reclamation.

### 3. Build-vs-buy table

| Layer | Library candidate | Build-from-scratch alternative | Recommendation |
|---|---|---|---|
| Hot overflow hashmap | `hashbrown::HashMap` / `FxHashMap` (already used) | n/a | **Buy** — `hashbrown` is already the SwissTable port; no FFI wins |
| Left-right reader wrapper | `arc-swap` (atomic Arc swap) | Custom epoch counter | **Buy** — `arc-swap` is the canonical Rust wait-free read primitive |
| Per-layer MPHF | **PtrHash** (`ptr_hash` crate, MIT, SEA 2025) | Existing BBHash; or vendored `odht` open-addressing table | **Buy PtrHash** (2.4 bits/key, 8.7 ns/lookup, epserde mmap). Fallback: vendor `odht` (rustc-proven, no dep weight, slightly worse storage) |
| Per-layer fingerprint array | n/a (just a `&[u32]`) | Custom mmap'd flat array | **Build** — trivial bytemuck cast |
| Per-layer payload array | n/a (just a `&[u8]`) | Custom mmap'd flat array | **Build** — trivial bytemuck cast |
| Per-layer cold-tier prefilter (L3+) | `xorf` (ribbon/xor filters, MIT) | Custom Bloom | **Buy** `xorf` (~7 bits/key ribbon, 1 cache miss, maintained 2025) |
| mmap glue | `memmap2` | n/a | **Buy** — 11K+ reverse deps, the only sensible choice |
| Epoch reclamation | `crossbeam-epoch` | Custom generation counter | **Buy** — production-tested, Rust-native |
| Zero-copy struct casting | `bytemuck` | Manual `unsafe` casts | **Buy** — saves a lot of `unsafe` |
| Layer stack publish | `arc-swap` | Custom RCU | **Buy** |
| File format / header / on-disk layout | n/a | Custom Rust + bytemuck | **Build** — domain-specific |
| Freeze / compaction logic | n/a | Custom Rust | **Build** — domain-specific |
| Hot overflow B-tree / range index | redb, LMDB-via-heed, libmdbx | n/a | **Reject all** — Report 2's analysis: storage budget alone disqualifies B+tree designs at 10B scale, plus we pay log(n) cache misses we don't need |
| Existing BBHash MPHF | `boomphf` | n/a | **Migrate away** — PtrHash beats it on every metric |

### 4. Implementation phases

**Phase 1: Fingerprint at existing MPHF slots** (2-3 days, low risk, independently shippable)
- Add a `u32 fingerprint[]` array alongside the existing BBHash MPHF + payload arrays on each frozen layer.
- On lookup, compare `fingerprint[slot] == hash32(key)`; mismatch → absent.
- **Memory delta**: +4 bytes/key per frozen layer. For current 250M-1B scale: +1-4 GB total.
- **Risk**: Low. Tests the false-positive-elimination story and the file-format-extension path without changing data structures.
- **Outcome**: Validates that fingerprint eliminates the "MPHF returns garbage on unknown key" hazard. Catches any pre-existing bugs where we relied on MPHF behavior implicitly.

**Phase 2: PtrHash migration (per-layer)** (3-5 days, medium risk, independently shippable)
- Replace `boomphf::Mphf` with `ptr_hash::PtrHash` for newly-built frozen layers; keep BBHash for already-on-disk layers via a version flag in the layer header.
- Add epserde feature for zero-copy mmap deserialization.
- **Memory delta**: -1 to -2 bits/key on new layers. At 1B keys: ~125-250 MB saved. At 10B: 1.25-2.5 GB.
- **Risk**: Medium — PtrHash is 2025-vintage; needs a multi-day soak test on a 100M+ layer to confirm no construction stability surprises. Fallback to vendored `odht` if PtrHash misbehaves.
- **Outcome**: ~2× lookup-speed improvement per Report 1 + Report 4 benchmarks. Validates the smaller-MPHF storage story we need at 10B scale.

**Phase 3: Left-right hot overflow + arc-swap publish** (4-5 days, medium risk, independently shippable)
- Wrap per-thread `FxHashMap` in a left-right buffer using `arc-swap`. Freeze coordinator builds the new frozen layer in background; reader threads never block.
- Switch the layer-stack root from whatever the current synchronization is to `ArcSwap<LayerStack>`.
- Add `crossbeam-epoch` for deferred munmap of superseded layers.
- **Memory delta**: +1 hot map per thread during freeze window (~160 MB × 32 = 5 GB transient). Returns to baseline after freeze completes.
- **Risk**: Medium — concurrency correctness is the highest-stakes part. Build a stress test that fires 1M lookups/sec across 32 threads during a synthetic freeze cycle and check for missing keys, stale reads, segfaults.
- **Outcome**: Eliminates reader-side freeze pauses. Makes the trainer steady-state-latency-flat.

**Phase 4: Size-tiered compaction with arena-per-generation** (1-2 weeks, high risk, independently shippable but high blast radius)
- Implement L0-L4 size-tiered geometry (fanout 4). Compactor thread merges 4 layers at a level into one at the next level when triggered.
- Switch f32 arenas from one-file-grows-forever to arena-per-generation. New compaction writes survivors to a fresh arena segment; old segments unmapped via `crossbeam-epoch` once reader epoch advances.
- **Memory delta**: At steady state, +1 generation of arena alive during compaction (~10-20% transient overhead). Compaction recovers space from sparse old generations.
- **Risk**: High — the dangling-reference invariant ("never overwrite a live arena slot") must be airtight. Build a debug mode that fills the old generation with poison bytes immediately on reclaim and runs a 24-hour fuzz test before deploying.
- **Outcome**: Bounds total layer count to ~5 (max ~5 MPHF probes per lookup, ~100-150 ns cold). Bounds storage by reclaiming garbage from old generations. Enables the 5B-10B scale targets.

**Phase 5: Cold-tier ribbon prefilter + NUMA replication + hugepages** (1 week, low-medium risk, independently shippable)
- Add `xorf` ribbon prefilter (4-7 bits/key) to L3 and L4 layers; skip MPHF probe on absent keys.
- Audit startup: `MADV_HUGEPAGE` on all arenas, `MADV_RANDOM` on payload arenas, `mlock` the deepest layer's ctrl+fingerprint arrays (verify RAM budget), `set_mempolicy(MPOL_INTERLEAVE)` before rayon spawn.
- Batch the 8 MCCFR per-iter lookups with explicit `_mm_prefetch`.
- **Memory delta**: +4-7 bits/key on deep layers (~6-10 GB at 10B). NUMA-replicated ctrl array on hot layer: +per-node copy (~1-2 GB total).
- **Risk**: Low-medium — well-trodden territory per Report 5. Main risk is THP defrag stalls; mitigation is `transparent_hugepage/defrag = madvise`.
- **Outcome**: 15-40% lookup latency reduction. Critical for the 32K lookups/sec target at 10B scale.

### 5. Open questions

1. **PtrHash construction stability at 1B+ keys in our specific key distribution.** PtrHash's paper benchmarks are on 1B keys but with random hashes; our keys are u64 hashes of (RBM bucket + board bucket + betting history), which should be uniform but warrants empirical verification before committing. **Decision needed before Phase 2.**
2. **Fingerprint width: u16 (FPR ≈ 1.5e-5) vs u32 (FPR ≈ 2.3e-10) vs u64 (zero FPR).** u32 is the Report 6 default. If we observe >10K spurious lookups/sec at 10B scale, we may need u64. **Decision: start with u32, measure spurious-rate at 1B before scaling.**
3. **Should the cold-tier prefilter be ribbon (smaller) or cache-line Bloom (faster)?** `xorf` ships both; Report 6 leans ribbon for memory-efficiency. Bench both on representative cold-key workload before committing.
4. **NUMA topology of the actual EPYC box.** Multi-CCD without multi-socket means uniform memory access but non-uniform L3. The interleave-vs-replicate decision depends on measured remote-L3 latency. **Decision deferred to Phase 5; measure on actual hardware.**
5. **Compaction trigger policy: count-based (4 layers per level) vs size-based vs time-based.** Report 6 recommends count-based. If freeze cadence is irregular under skewed key distributions, we may want a hybrid. **Decision deferred to Phase 4 after Phase 3 stress tests.**
6. **Total RBP-style pruning at freeze (drop entries with very negative regret).** Report 3 highlights this as Libratus's biggest single space-saver. Orthogonal to the index design but worth a separate exploration thread. **Out of scope for this design; queue as separate work item.**
7. **Whether to densify betting-history into a Slumbot-style `nonterminal_id` and bucket-IDs into dense ints, eliminating the hashmap entirely.** Report 3's biggest architectural-win recommendation. Requires freezing RBM cluster IDs after discovery phase. **Out of scope for index design; this is a different project**.

### 6. Things to ignore

- **LMDB / libmdbx / heed / redb / B+tree designs (Report 2).** All disqualified by storage budget: B+tree overhead at 10B u64-keyed entries → 280+ GB. We don't need ACID, range scans, or transactions, so we're paying log(n) cache misses and B+tree page overhead for nothing.
- **RocksDB / LevelDB / sled.** LSM general-purpose stores with WAL, compression, transactions, range scans — every dimension we don't need. RocksDB's mmap mode is explicitly deprecated by Facebook. sled's author tells you not to use it.
- **odht as primary choice.** Excellent crate, rustc-team-quality, but last release 2021. We keep it as the **fallback for PtrHash** if PtrHash construction proves unstable. Vendoring 3K lines from 2021 is fine; making it the primary dependency is unnecessary risk vs. the actively-maintained PtrHash.
- **rkyv `ArchivedHashMap`.** Heavier dep tree, slightly slower than odht, and we don't get anything PtrHash + custom flat arrays don't give us. Reject.
- **FFI to libcuckoo, abseil, F14, Folly.** Report 4 + Report 2 are unanimous: hashbrown (Rust's SwissTable) is already at or above C++ hashmap performance for u64 keys, and the FFI tax wipes out any single-digit-percent win.
- **Lock-free dynamic concurrent hashmaps (NBHM, papaya, GrowT, DashMap as primary store).** Report 4's analysis: our writer is single during freeze, our reads are 99.99% to read-only frozen structures. Lock-free machinery is paid-for-but-unused; the version-counter and GC overhead actively hurts the read-side cache.
- **Robin Hood hashing.** Report 5: insertion shuffle dirties extra mmap pages on every write. SwissTable's SIMD batching wins on warm lookups and is cleaner on writes.
- **HAMT, sorted array + binary search, FST.** Pointer-chasing or log(n) cache misses kill them at our scale.
- **Bloom filter in front of MPHF on shallow layers.** Report 6's clearest finding: 32-bit fingerprint at the MPHF slot strictly dominates Bloom for u64 keys because it piggybacks on the lookup you were going to do anyway, with zero extra hashes and FPR ≈ 2^-32.
- **Leveled compaction (RocksDB fanout 10) and PebblesDB FLSM guards.** Designed for random-write workloads with range queries. Our writes are batched and our reads are point lookups. Size-tiered fanout 4 is the right shape.
- **Bourbon-style learned indices.** Hashed keys have uniform CDF; there's nothing to learn.
- **Ribbon at L0.** Ribbon construction cost only amortizes for layers living >1 hour per RocksDB. Our L0 turns over every few minutes. Use Bloom at shallow layers if at all (preferred: no filter, just fingerprint).
- **1 GiB hugepages.** Worst-case 2.5× slower than 4 KiB at our scale; only 4 L1 TLB entries on typical EPYC. 2 MiB is the only sensible hugepage size.
- **`MAP_POPULATE` on the whole index.** Will block startup for minutes and not all pages fit anyway. Use `MADV_POPULATE_READ` only on the ctrl/fingerprint arrays of the hottest layer.
- **Total RBP space reclamation, dense-int betting-history densification, NN-as-value-function (Report 3).** All real architectural wins from prior art, but orthogonal to this index design. Queue separately.