I have sufficient material now to produce the comprehensive survey. Let me synthesize the report.

# Concurrent Hashmap Survey for MCCFR Workload

## Workload-Specific Lens (the reading frame for every entry below)

Reads:writes = 10000:1, batched single-writer during freeze, 32 reader threads, 8 lookups per iter, ~32K lookups/sec aggregate. Lookup tail is wide (poor locality). Per-LOOKUP cache miss is unacceptable; per-iter cache miss is fine. Storage target: <120GB working set at 10B entries → ~12 bytes/entry budget. **This workload is closer to "static index with mutable overlay" than to "concurrent hashmap."**

---

## Master Comparison Table

| Algorithm | Reader concurrency | Writer concurrency | Cache lines / hit | Cache lines / miss | Probe length (95%ile) | Memory overhead | Mmap-friendly | Resize | Fit for our workload |
|---|---|---|---|---|---|---|---|---|---|
| **SwissTable** | Not concurrent (per-thread or wrap with RwLock) | Single | 1 (group) + 1 (slot) typical | 1 (group) | ≤16 (group) | ~12.5% (1/8 byte ctrl + load) | Yes (flat array) | STW | Strong baseline; needs sharding |
| **F14** | Not concurrent | Single | 1 (chunk, full) | 1 (chunk) | ≤14 per chunk; double-hash to other chunks | ~7% (1/14 tag) | Yes | STW | Slightly tighter than SwissTable on u64 |
| **Cuckoo (libcuckoo)** | Optimistic (lock-free reads w/ version counters) | Multi via fine-grained locks | 2 (both candidate buckets) | 2 | 2 (worst-case constant!) | 50% loose; 95% w/ bucketing | Pure-MPHF mode: yes | STW or move-resize | Best worst-case latency; reads do 2x prefetchable misses |
| **Robin Hood** | Not concurrent (typically) | Single | 1 (slot) | 1 (slot) | Low variance, ~6–10 at 90% load | <10% | Yes | STW | Variance win is nice but single SwissTable group is faster |
| **Hopscotch** | Concurrent (locking subset) | Multi (segment lock) | 1 (neighborhood, H=32) | 1 | H=32 (bounded!) | ~10% | Yes | STW | Original concurrent design; superseded by SwissTable-family for our shape |
| **Cliff Click NBHM** | Lock-free | Lock-free (CAS) | 1–2 | 2 | Unbounded but rare | High (Java) | No (boxed) | Online migration | Lock-free is wasted given batched writes |
| **Java ConcurrentHashMap** | Mostly lock-free | Multi (stripe / CAS) | 1–2 | 2+ | Bucket size (treeified after 8) | High (Java) | No | Incremental | Same critique as NBHM |
| **liburcu rculfhash** | Wait-free reader (RCU grace) | Lock-free | 2 (list traversal) | 2+ | Bucket chain | High | No | Online | Wait-free reads great, but linked-list cache behavior is bad |
| **Split-ordered list (Shalev–Shavit)** | Lock-free | Lock-free | ≥2 (list nodes) | 2+ | Bucket chain | High | No | Online | Pointer-chasing dominates; bad fit |
| **left-right (Ramalhete)** | Wait-free reader (2 copies) | Single | Whatever inner map costs | Same | Inner map | 2× inner map | Yes if inner is flat | Atomic version flip | **Excellent semantic match** with our freeze cycle |
| **MPHF (BBHash/PTHash/PHOBIC)** | Wait-free (read-only) | None (rebuild) | 1 (slot) + bits for MPHF lookup | 1–2 | O(1), 1 cache line w/ small key | **2.07–3.7 bits/key** | Yes (flat arrays) | Rebuild only | **Best fit** for frozen layers |
| **HAMT** | Persistent/structural sharing | Functional CoW | 5–7 (trie depth) | 5+ | log32 N | High (pointers) | Marginal | Persistent, no resize | Pointer chasing kills it |
| **Sorted array + binary search** | Wait-free | None (rebuild) | ~log2 N (worst), ~3–4 w/ Eytzinger | Same | log2 N | 0% overhead | Yes (flatest possible) | Rebuild | Loses to MPHF on cache misses but tiny build cost |
| **DashMap (sharded RwLock)** | Multi via shard RwLock | Multi via shard RwLock | 1–2 | 2 | SwissTable inside shard | ~12.5% + shards | Rust-only, no mmap | STW per shard | Easy drop-in; not optimal |
| **papaya (seize GC)** | Lock-free | Lock-free (CAS) | 1–2 | 2 | Linear probe | ~25% | No (heap allocated) | Online migration | Overkill for batched-write scenario |
| **evmap / left-right pattern** | Wait-free reader | Single, deferred apply | Same as inner | Same | Same | 2× inner | If inner mmaps, yes | Atomic ptr flip | **Drop-in fit for freeze cycle** |
| **GrowT (Maier–Sanders)** | Lock-free | Lock-free (CAS) | 1 | 1 | Linear probe (small) | <15% | No (heap) | Online migration | Lock-free overhead wasted |
| **FaRM-style Hopscotch + version** | Optimistic read | Single (RDMA) | 1 (neighborhood) | 1 | H bounded | ~10% | Yes | STW | Inspirational; not directly applicable |

---

## Algorithm-by-Algorithm Detail

### 1. SwissTable (Abseil / Google)

- **Paper / source**: Abseil design doc; "Designing a Fast, Efficient, Cache-friendly Hash Table" (CppCon 2017, Matt Kulukundis)
- **Layout**: Open-addressed flat array + parallel control-byte array. Control byte = 1 bit empty/deleted/full + 7-bit H2 hash. Groups of 16 control bytes scanned via SSE2 (`_mm_cmpeq_epi8` + `_mm_movemask_epi8`).
- **Lookup cost**: 1 cache-line load for the control group, ~1 more for slot access. On hit, the SIMD scan resolves 16 candidates in one shot, so amortized cache misses per lookup ≈ 1.0–1.3.
- **Load factor**: up to 7/8 (87.5%).
- **Concurrency**: not built-in. Must wrap with RwLock or shard.
- **Resize**: stop-the-world; rehash to a 2x table.
- **Production**: Abseil flat_hash_map, Rust std HashMap (hashbrown), Go runtime maps (1.24+ phased migration), CockroachDB, ClickHouse.
- **Fit**: Excellent as the inner map of a per-shard or left-right design. Per the Abseil docs, the SSE-driven control-byte scan is its core differentiator.

### 2. F14 (Facebook / Meta)

- **Source**: facebook/folly F14.md; Meta engineering blog 2019.
- **Layout**: 14-way chunked. Each chunk: 14 tag bytes (1 byte each, 7 entropy bits) + 2 metadata bytes packed into 16-byte SSE register. Optionally 12 slots for 4-byte values so a chunk fits 1 cache line exactly.
- **Lookup**: SSE2 / NEON parallel tag compare → bitmask of candidates within chunk; double-hash to other chunks on overflow.
- **Cache**: 1 line for typical lookup (chunk fits cache line). Comparable to SwissTable but slightly tighter for small values.
- **Concurrency**: none.
- **Resize**: STW.
- **Fit**: Equivalent to SwissTable for our purposes; pick whichever your language ecosystem ships natively (Rust → hashbrown/SwissTable).

### 3. Cuckoo Hashing (libcuckoo)

- **Paper**: Li, Andersen, Kaminsky, Freedman, "Algorithmic Improvements for Fast Concurrent Cuckoo Hashing" (EuroSys 2014).
- **Layout**: Two tables (or one with two hash functions). Each "bucket" holds ≥4 slots; libcuckoo uses bucketization for 90%+ load factor.
- **Lookup**: 2 cache-line loads (one per candidate bucket), both prefetchable in parallel. Worst-case 2 misses = bounded.
- **Insert**: amortized O(1), pathological eviction chains; libcuckoo handles via per-bucket fine-grained locks + optimistic versioning for readers.
- **Concurrency**: optimistic lock-free reads via version counters, multi-writer via striped locks.
- **Memory**: bucketized version achieves 95% load factor at ~5% overhead.
- **Resize**: incremental (rehash on contention).
- **Fit**: Great worst-case bound (2 misses, prefetchable). The Princeton paper reports 2.5x throughput vs. comparable concurrent tables. If we want a single dynamic concurrent map (option b), libcuckoo's algorithm is the strongest candidate.

### 4. Robin Hood Hashing

- **Paper**: Celis 1986; arXiv 1605.04031 (Janson 2016, constant variance proof).
- **Idea**: On collision, "rich" entries (close to home) yield to "poor" entries (far from home). Drastically reduces probe length variance.
- **Lookup**: 1 cache line in common case; tail at 90% load factor stays at ~10 probes (constant variance even when nearly full per Janson).
- **Concurrency**: not natural; relies on element movement.
- **Production**: Rust's hashbrown originally; superseded by SwissTable in 2018.
- **Fit**: Variance win matters less than SwissTable's SIMD batching for our workload. Skip.

### 5. Hopscotch Hashing

- **Paper**: Herlihy, Shavit, Tzafrir, "Hopscotch Hashing" (DISC 2008).
- **Layout**: Each bucket has a neighborhood of H consecutive slots (H=32 or 64). Probe limited to neighborhood.
- **Lookup**: bounded H probes, but contiguous → 1–2 cache lines.
- **Concurrency**: original is concurrent with per-segment locks; lock-free variant in arXiv 1911.03028.
- **Production**: FaRM (MS Research) uses hopscotch for RDMA KV store. Influenced subsequent concurrent table designs.
- **Fit**: bounded probe length is appealing, but SwissTable's bitmask scan beats it on modern x86. Hopscotch's main draw is concurrent insert support, which we don't need at our 1:10000 write ratio.

### 6. Cliff Click NonBlockingHashMap

- **Paper**: JavaOne 2007 / InfoQ 2008 talk; impl in `org.cliffc.high_scale_lib`.
- **Idea**: Per-array-slot finite-state-machine with CAS-driven state transitions. Every operation makes progress; no locks anywhere.
- **Production**: Azul JVM internals; Cassandra; Hazelcast (concept).
- **Memory**: heavy (Java boxing).
- **Resize**: helper-thread incremental migration; readers can help.
- **Fit**: Lock-free reads are wasted on us — reads are already going to a frozen, read-only structure 99.99% of the time. The complexity isn't paid for.

### 7. Java ConcurrentHashMap (Doug Lea)

- **Algorithm**: pre-Java 8: 16-segment striped lock; Java 8+: lock-free reads, CAS+sync for updates, treeifies after 8 collisions.
- **Layout**: linked-list-of-Nodes per bucket (no flat probe).
- **Concurrency**: multi-writer, multi-reader. Resize is incremental.
- **Fit**: Pointer-chasing per bucket is bad for our cache profile. Skip.

### 8. liburcu rculfhash (Mathieu Desnoyers)

- **Algorithm**: Split-ordered list (Shalev–Shavit) with RCU-protected nodes. Wait-free readers (RCU read-side critical section). Lock-free writers.
- **Lookup**: linked-list traversal within bucket → minimum 2 cache-misses, more under collisions.
- **Resize**: online, lock-free, doubling.
- **Production**: LTTng, IBM tracing, Suricata.
- **Fit**: Wait-free reads are great in principle, but the linked-list layout is the worst possible cache shape for our 32-thread cache-miss-sensitive workload.

### 9. Split-ordered List (Shalev–Shavit, JACM 2006)

- The algorithmic basis for liburcu's rculfhash. Same critique: cache-hostile node layout. Mainly of historical interest unless wrapped with flat-bucket variants.

### 10. left-right (Ramalhete & Craveiro 2013)

- **Paper**: "Brief Announcement: Left-Right" (DISC 2013), HAL hal-01207881.
- **Idea**: Maintain two copies of the underlying structure. Writers apply each update twice with an atomic version flip in between. Readers atomically read which copy is "active" and proceed wait-free with population-oblivious cost.
- **Memory**: 2× inner.
- **Concurrency**: wait-free reader (no shared state read by writer), single writer, no allocation.
- **Production**: evmap (Rust, Jon Gjengset), C++ implementations.
- **Fit for us**: **This is structurally the cleanest match** for batched single-writer / multi-reader. Cost is 2× memory (a hard problem at 10B entries). But you could limit the left-right to the *hot mutable buffer*, not the frozen layers.

### 11. Minimal Perfect Hash Functions (BBHash, PTHash, PHOBIC, RecSplit)

- **Papers**:
  - Limasset et al., BBHash, "Fast and Scalable Minimal Perfect Hashing for Massive Key Sets" (SEA 2017)
  - Pibiri & Trani, PTHash (SIGIR 2021), Parallel/External-Memory PTHash (TKDE 2023)
  - PHOBIC (ESA 2024) — 2.17 bits/key
  - PtrHash (arXiv 2502.15539, 2025) — RAM-throughput query
- **Construction**: BBHash O(n) time, 5GB RAM for 10^10 keys in 7 min on 8 threads
- **Space**: BBHash 2.89–6.9 bits/key (tunable γ); PTHash 2.40 bits/key; PHOBIC 2.17 bits/key
- **Lookup**: 1 cache line for MPHF metadata + 1 for slot. PHOBIC reports ~37ns/query. BBHash benchmark reports ~244ns/query (older, but PtrHash is 1.75x+ faster than legacy MPHFs)
- **Concurrency**: read-only — wait-free trivially, since no writes can occur.
- **Resize**: rebuild. Construction is fast enough for our freeze cycle (every 1M iters per thread → freeze every few minutes is fine).
- **Production**: Qdrant uses ph crate (fingerprint MPHF) for vector index. Bioinformatics tools (kraken, BBHash use cases).
- **Fit for us**: **Strongest candidate for the frozen layer**. At 2.4 bits/key, 1B entries = 300MB MPHF metadata. 10B entries = 3GB. Lookup is single-digit cache misses (often just 1 if MPHF table fits in L2/L3 working set).

### 12. HAMT (Hash Array Mapped Trie, Bagwell 2000)

- **Paper**: Phil Bagwell, "Ideal Hash Trees", 2000.
- **Layout**: tree of arrays indexed by 5-bit hash slices.
- **Lookup**: log32 N pointer dereferences → ~5 cache misses at 10B entries.
- **Production**: Clojure, Scala, Frege immutable map types.
- **Fit**: Per-lookup cache miss count is the showstopper. Skip.

### 13. Sorted Array + Binary Search

- **Layout**: flat sorted u64 keys + parallel offsets array.
- **Lookup**: log2 N comparisons; with Eytzinger / cache-blocked layout ~3–4 cache misses (Khuong 2012 and arXiv 1509.05053).
- **Build**: O(N log N) sort.
- **Concurrency**: read-only after build → wait-free.
- **Memory**: 0% overhead beyond keys+values.
- **Fit**: Beats MPHF on construction simplicity; loses on lookup cache misses (log N vs 1–2). At 1B keys, log2 = 30 comparisons → 4–6 cache lines with Eytzinger. **Useful as a baseline / sanity layer**, not as the production lookup path.

### 14. DashMap (Rust)

- **Algorithm**: N=#CPU shards of `RwLock<hashbrown::HashMap>`. Hash → shard → SwissTable lookup.
- **Concurrency**: multi-reader, multi-writer at the cost of one RwLock per shard.
- **Production**: Many Rust services; convox; tikv (partial).
- **Fit**: Convenient drop-in. The shard RwLock is overkill for our 1:10000 writes — you'd hold reader locks 99.99% of the time, defeating the lock entirely. Fine as a hot-buffer stand-in.

### 15. papaya (Ibraheem Ahmed)

- **Algorithm**: Lock-free SwissTable variant with seize-based epoch GC for safe migration. Reads are direct references (no cloning).
- **Concurrency**: lock-free reads/writes via CAS on control bytes.
- **Memory**: ~25%–50% overhead (similar to typical lock-free).
- **Fit**: Excellent if we needed concurrent writes. We don't. Skip in favor of left-right or sharded if dynamic-only.

### 16. GrowT (Maier & Sanders)

- **Paper**: "Concurrent Hash Tables: Fast and General(?)" (TOPC 2019).
- **Algorithm**: Header-only C++ family of lock-free dynamic concurrent hash tables. Migration in background.
- **Production**: TBB-adjacent, KIT research code.
- **Fit**: C++ only, no Rust binding. Same critique as papaya — lock-free unneeded.

### 17. evmap / left-right Pattern (Jon Gjengset, Rust)

- **Algorithm**: Maintain 2 inner maps (whatever type). Writers append to a journal, periodically `refresh()` flips active pointer with `AcqRel` ordering.
- **Concurrency**: wait-free readers via `arc-swap`; single writer.
- **Memory**: 2× inner.
- **Fit for us**: Direct semantic match for freeze cycles. Inner can be hashbrown or a custom mmap-backed thing.

### 18. FaRM-Style Hopscotch + Versioning

- Mentioned for completeness. Microsoft FaRM uses hopscotch + per-slot version numbers for RDMA-friendly single-RTT reads. Conceptually informs how you'd add version-counter optimistic reads to a hopscotch overlay buffer. Implementation lift is high.

---

## The Explicit Question: Frozen MPHF Layers + Mutable Buffer, or One Dynamic Concurrent Map?

### Side (a): Frozen Per-Era MPHF + Mutable Hot Buffer — argument

1. **Read-path cache profile is unbeatable**. Lookup = 1 cache line of MPHF metadata (often L2/L3 resident, hot) + 1 line for slot. The MPHF "absorbs" the hash distribution into a bijection over [0..N), so the offset array is a single flat dense `[u64; N]`. We've put the lookup cost at its theoretical floor.

2. **Storage budget hits target**. At 2.07 bits/key (PHOBIC) to 3.7 bits/key (BBHash): 10B keys = 2.5–4.6GB MPHF + (10B × 12 bytes for `(offset, n_actions, epoch)`) = ~120GB total — *exactly the constraint*. SwissTable at 12.5% overhead on 16-byte entries = 180GB → blows the budget. F14 maybe gets to 130GB → tight.

3. **Mmap-clean**. MPHF tables and offset arrays are flat. mmap them. The OS page cache becomes a 32-thread-aware tail cache for the wide-tail tier without us writing any cache code.

4. **Build cost is amortized**. BBHash: 10^10 keys in 7 min on 8 threads. Our freeze cycle is every ~1M iters per thread = ~few minutes wall-clock. So MPHF construction parallel to next freeze cycle's CFR iters is nearly free.

5. **Write path is trivially correct**. New info-sets go into a `FxHashMap` (or DashMap shard) until the next freeze. At freeze: drain hot buffer, sort/dedupe, rebuild MPHF for new era as a new layer. *This is what we already do (LSM-style)*. The question is whether to keep the per-era MPHF or replace it.

6. **Wait-free reads, by construction**. A frozen layer has no writers ever. No version counters, no RCU grace periods, no lock acquisitions. The MPHF is the closest thing to "physically read-only" that a data structure can be.

7. **Multi-layer read amplification is bounded**. With leveled compaction (log N layers): at 10B entries with 1M-entry hot buffer = 14 levels worst case. Bloom filter on each level (8 bits/key = 12.5GB at 10B) reduces almost all of these to a single MPHF probe.

### Side (b): Single Concurrent Dynamic Hashmap — argument

1. **Operational simplicity**. One data structure, one set of invariants. No layer rebuild logic, no compaction policy, no bloom filter tuning.

2. **No multi-layer read amp at all**. Worst case is one bucket probe. No need to filter out N layers and bloom-falsify.

3. **Insert tail latency is uniform**. With LSM you get periodic STW freeze pauses where readers might block (or hit a transitional layer). A single dynamic concurrent map has steady-state insert cost.

4. **Cache profile is also good**. libcuckoo (2 misses worst case, both prefetchable) or sharded SwissTable (1 cache miss typical) give ≤2 misses with no MPHF metadata to keep hot.

5. **Smaller engineering surface to maintain**. We have one paper experiment's worth of effort here. Adopt DashMap or libcuckoo; move on.

6. **No "epoch" semantics to leak into the rest of the codebase**. With per-era MPHFs we have to remember which layer owns each info-set, handle epoch boundaries in `last_discount_epoch`, etc.

### Conclusion

**Option (a) wins for this workload, but pragmatically modify the LSM-style design you already have rather than rewrite.**

Decisive arguments:

- **Storage budget is the hard constraint**. The 10B target *requires* ~12 bytes/entry. Dynamic concurrent hashmaps can't get there: SwissTable 14.3% overhead on a 16-byte entry → 18.3 bytes/entry → 183GB at 10B. libcuckoo at 95% load factor on 16-byte entries → ~16.8 bytes/entry → 168GB. **Only MPHF + flat offset arrays meet 12 bytes/entry.**

- **Read profile is the second hard constraint**. A 1-line MPHF probe + 1-line offset load is the theoretical floor. Any concurrent dynamic map adds at least 1 indirection (and usually 2 cache misses) just to handle the concurrent-write machinery we don't need.

- **You already have an LSM-style frozen-layer design**. The question simplifies to: *use which MPHF for each frozen layer, and how to bound the read amplification.*

Recommendation:
1. **Frozen layers**: switch from BBHash to **PTHash** or **PHOBIC** (2.17–2.4 bits/key vs BBHash's 3.7). At 10B entries this is a 1.5GB savings on the MPHF alone, and queries are 1.75x+ faster per PtrHash benchmarks.
2. **Hot mutable buffer**: keep per-thread `FxHashMap<u64, CompactEntry>` (already in your design). Or, since we only have one writer at freeze time, consider a **left-right (evmap-style)** wrapper around a hashbrown SwissTable so 32 readers see a wait-free consistent view while the freeze thread builds the next MPHF in the background. This eliminates any read-side blocking during freeze.
3. **Read amplification control**: add an **8-bit-per-key bloom filter** per frozen layer (or quotient filter / xor filter, which is smaller at ~3 bits/key with similar false-positive rate). At 10B entries this is ~4GB and reduces multi-layer probes to 1 expected per lookup.
4. **Optional**: when freeze produces a new layer, kick off background **leveled compaction** (merge K most-recent levels into one larger MPHF). Bounds total layer count to O(log_K N).

For the *concurrent dynamic map fallback* — if MPHF rebuild ends up too painful operationally — the next-best option is **libcuckoo-style bucketized cuckoo hashing** (2 prefetchable cache misses worst case, 95% load factor). Avoid lock-free designs (NBHM, papaya, GrowT) — their writer concurrency is unused on our workload and the version-counter / GC machinery hurts read-side cache.

The **left-right (Ramalhete) pattern** is the wildcard worth prototyping: it gives wait-free readers with single-writer semantics over *any* inner map, which is exactly your access shape. The 2× memory cost is the catch — applicable only to the hot mutable buffer, not the frozen layers.

---

## File / Path References

No project files modified — research-only task. Existing relevant project paths:
- `/home/struktured/projects/recursive-bipartite-matching/CLAUDE.md` — workload context for RBM/MCCFR
- Project's Rust trainer (referenced in memory: `runbook_session_restart.md`, `project_parallel_rbm_results.md`)

Sources:
- [Abseil SwissTables design](https://abseil.io/about/design/swisstables)
- [Folly F14 documentation](https://github.com/facebook/folly/blob/main/folly/container/F14.md)
- [Open-sourcing F14 (Meta Engineering)](https://engineering.fb.com/2019/04/25/developer-tools/f14/)
- [Li, Andersen et al., libcuckoo paper (EuroSys 2014)](https://www.cs.princeton.edu/~mfreed/docs/cuckoo-eurosys14.pdf)
- [libcuckoo GitHub](https://github.com/efficient/libcuckoo)
- [Robin Hood hashing (Code Capsule)](https://codecapsule.com/2013/11/11/robin-hood-hashing/)
- [Janson 2016, Robin Hood constant variance (arXiv 1605.04031)](https://arxiv.org/pdf/1605.04031)
- [Herlihy, Shavit, Tzafrir, Hopscotch Hashing (DISC 2008)](https://people.csail.mit.edu/shanir/publications/disc2008_submission_98.pdf)
- [Lock-Free Hopscotch Hashing (arXiv 1911.03028)](https://arxiv.org/pdf/1911.03028)
- [Cliff Click NonBlockingHashMap (InfoQ)](https://www.infoq.com/news/2008/05/click_non_blocking/)
- [high-scale-lib NonBlockingHashMap source](https://github.com/boundary/high-scale-lib/blob/master/src/main/java/org/cliffc/high_scale_lib/NonBlockingHashMap.java)
- [Java ConcurrentHashMap internals (Burnison)](https://www.burnison.ca/articles/the-concurrency-of-concurrenthashmap)
- [liburcu userspace-rcu](https://liburcu.org/)
- [URCU-protected hash tables (LWN)](https://lwn.net/Articles/573431/)
- [Shalev & Shavit, Split-ordered Lists (JACM 2006)](https://www.cs.tau.ac.il/~afek/SplitOrderListHashSS03.pdf)
- [Ramalhete & Craveiro, Left-Right (HAL hal-01207881)](https://hal.science/hal-01207881v1/preview/39-BA.pdf)
- [Left-Right wait-free reading (nicknash.me)](https://nicknash.me/2018/05/01/left-right-wait-free-reading-while-writing/)
- [BBHash paper (Limasset et al., SEA 2017)](https://arxiv.org/pdf/1702.03154)
- [BBHash GitHub](https://github.com/rizkg/BBHash)
- [PTHash paper (SIGIR 2021)](https://jermp.github.io/assets/pdf/papers/SIGIR2021.pdf)
- [PTHash GitHub](https://github.com/jermp/pthash)
- [PHOBIC paper (arXiv 2404.18497)](https://arxiv.org/pdf/2404.18497)
- [PtrHash: Minimal Perfect Hashing at RAM Throughput](https://curiouscoding.nl/posts/ptrhash/)
- [Bagwell, Ideal Hash Trees (HAMT)](https://www.researchgate.net/publication/2378571_Ideal_Hash_Trees)
- [Khuong, "Binary search is a pathological case for caches"](https://pvk.ca/Blog/2012/07/30/binary-search-is-a-pathological-case-for-caches/)
- [Array Layouts for Comparison-Based Searching (arXiv 1509.05053)](https://arxiv.org/pdf/1509.05053)
- [DashMap GitHub](https://github.com/xacrimon/dashmap)
- [papaya GitHub + design post (Ibraheem Ahmed)](https://ibraheem.ca/posts/designing-papaya/)
- [GrowT (Maier & Sanders, TOPC 2019)](https://dl.acm.org/doi/abs/10.1145/3309206)
- [GrowT GitHub](https://github.com/TooBiased/growt)
- [evmap docs.rs](https://docs.rs/evmap/latest/evmap/)
- [FaRM-KV using hopscotch + OCC](https://pdos.csail.mit.edu/6.824/notes/l-farm.txt)
- [Cuckoo hashing benchmarks (Reiner)](https://reiner.org/cuckoo-hashing)
- [Qdrant immutable structures + MPHF](https://qdrant.tech/articles/immutable-data-structures/)