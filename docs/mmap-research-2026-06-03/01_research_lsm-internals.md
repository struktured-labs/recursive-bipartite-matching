I have enough material. Time to synthesize the focused deliverable.

---

# LSM Design Notes for an MCCFR Frozen-Layer Index

**Frame**: hash-keyed point lookups, 32 readers, 10000:1 read:write, periodic batched freeze. Reject anything that assumes random writes or range scans.

---

## 1. What LSM actually buys you (and what it doesn't)

Modern LSMs solve three problems we don't have:
- amortizing random writes into sequential I/O (we already batch on freeze)
- supporting range scans (we don't need any)
- ACID/snapshot isolation (we don't need any)

What we DO want from LSM literature:
- the **multi-tier probe pattern** (memtable → newest frozen → oldest frozen)
- **per-layer membership filters** to suppress useless probes
- **compaction geometry** to keep the layer count bounded so read amp stays flat

The literature confirms that lookup cost is dominated by the *sum of false-positive rates across layers* — and that the standard newest-first probe order short-circuits on hit ([Sarkar et al. VLDB 2021](https://vldb.org/pvldb/vol14/p2216-sarkar.pdf), [Dayan et al. TODS 2018 - Monkey](https://cs-people.bu.edu/mathan/publications/tods18-dayan.pdf)). Both apply to us directly.

---

## 2. Bloom filters vs. MPHFs in OUR setting

This is the most important question you asked, and the answer is non-obvious.

**A MPHF (BBHash, PtrHash, PHOBIC) does NOT differentiate known vs. unknown keys.** It is a *minimal perfect hash on the construction set only*. Querying an MPHF with a key that wasn't in the construction set returns an arbitrary slot in `[0, n)` — looks valid, points to a real entry, just the wrong one. There is no "absent" signal. ([BBHash paper](https://arxiv.org/pdf/1702.03154), [boomphf docs](https://10xgenomics.github.io/rust-boomphf/master/boomphf/hashmap/index.html))

So for absent-key probes you need EITHER:
- a bloom/ribbon/cuckoo filter in front of the MPHF, OR
- a **key fingerprint** stored at the MPHF-mapped slot, compared against the query's fingerprint

The fingerprint approach is what `boomphf::BoomHashMap` does — store the original key (or a 16/32-bit hash of it) alongside the value. With an 8-byte u64 query and an arena where slots are tightly packed, storing the **full 8-byte key** at the slot costs the same 64 bits/key that a Bloom filter at 1% FPR costs, but gives **zero false positives** and turns the lookup into a single cache-line load — no probabilistic filter probe before it.

**Recommendation: don't add a Bloom layer in front of your existing MPHF. Instead, store an 8-byte (or 4-byte truncated) key fingerprint at each MPHF slot.** Compare on read; mismatch == absent. This is strictly better than MPHF+Bloom for u64 keys because:

1. Bloom at 1% FPR is ~10 bits/key; ribbon at 1% is ~7 bits/key ([RocksDB Ribbon](https://rocksdb.org/blog/2021/12/29/ribbon-filter.html)). A 32-bit fingerprint is 32 bits/key but **eliminates** the secondary probe and gives FPR ≈ 2^-32.
2. Bloom requires k independent hashes per query (cache-line bloom is one cache miss; full filter is one). Fingerprint is zero hashes — you already have the key.
3. Both Cuckoo and Bloom filters have a cache-miss-per-probe cost that compounds across L layers ([Cuckoo Filter Conext 2014](https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf)). Fingerprint at the MPHF slot piggybacks on the lookup you were going to do anyway.

**Caveat: only if your read pattern hits the layer.** If most cold-key reads should be filtered out *before* the MPHF probe (e.g. because the MPHF query itself has nontrivial cost), then a Bloom-in-front-of-MPHF wins. BBHash MPHF query is ~50-100 ns per layer; with 4-8 layers that's 400ns just to walk the layers. So for **layers known to be cold**, a small (4 bits/key) Bloom filter saves the MPHF probe.

**Final answer to "do we need bloom filters per layer if MPHF differentiates known vs unknown":**
- MPHF does NOT differentiate. You must add a fingerprint (preferred) or a filter.
- A 32-bit fingerprint stored at each slot dominates Bloom for our u64 keys.
- Optionally add a tiny 4-bit/key Bloom or 8-bit/key ribbon in front of OLDER (large, rarely-hit) layers to skip the MPHF probe — this is the [Monkey](https://daslab.seas.harvard.edu/monkey/) "more bits at deeper levels" intuition inverted: at deep levels we want a Bloom AT ALL specifically because deep-level probes dominate cold-key cost.

---

## 3. Layer geometry — L0/L1/L2 sizing

Reject leveled compaction wholesale. The RocksDB-style geometry (L_n = 10 × L_{n-1}) is tuned for random-write workloads with 20-30× write amplification ([RocksDB Tuning Guide](https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide), [Windrose](https://borecraft.com/findings/windrose-rocksdb-findings.html)). We pay 0× write amp by batching, so we should optimize for **read amp = number of layers probed × FPR per layer**.

Use **size-tiered compaction with a small fanout**. Recommended geometry:

| Layer | Size | Trigger | Filter |
|-------|------|---------|--------|
| Hot overflow | ~10M entries (per thread FxHashMap) | freeze every ~1M iters | none — in heap |
| L0 | ~10M entries | merge 4 → L1 | 32-bit fingerprint at MPHF slot |
| L1 | ~40M | merge 4 → L2 | 32-bit fingerprint + 4-bit Bloom |
| L2 | ~160M | merge 4 → L3 | 32-bit fingerprint + 8-bit ribbon |
| L3 | ~640M | merge 4 → L4 | 32-bit fingerprint + 8-bit ribbon |
| L4+ | ~2.5B+ | terminal | 32-bit fingerprint + 10-bit ribbon |

Fanout 4 (not 10) because:
- Lower fanout = fewer entries rewritten per compaction = lower CPU during merge
- 4 layers at fanout-4 covers 10B keys (10M × 4^5 ≈ 10B) — matches your aspirational scale
- Read amp = at most 5 layers probed; with per-layer FPR ≈ 1% the false probe count is ≤ 0.05 per lookup

This is **tiered, not leveled**. Tiered hits ~1.2-1.8× higher read amp than leveled but ~2-4× lower write amp ([VLDB 2021 design space](https://vldb.org/pvldb/vol14/p2216-sarkar.pdf), [Scavenger 2025](https://www.arxiv.org/pdf/2508.13909)), and write amp is what kills us during freeze stalls.

---

## 4. Layer probe order

**Newest-first, always**, with early-exit on hit. This is the universal LSM probe order ([Sarkar et al.](https://vldb.org/pvldb/vol14/p2216-sarkar.pdf)). For MCCFR specifically:

- Recently-frozen layers contain recently-trained info sets → temporal locality says these are also recently-read
- Cold (deep) layers are accessed only on tail-of-distribution hands → MPHF + Bloom suppresses the probe

DO NOT sort by hash range. That makes sense for B-tree-style indices and SSTable range-tagging; it's irrelevant for hash-keyed point lookups and forces every layer to be probed.

---

## 5. WiscKey / KV separation — yes, we already do it

You already have it: the arenas hold regret + strategy floats, the LSM holds (key → offset). This is exactly the [WiscKey](https://pages.cs.wisc.edu/~ll/papers/wisckey.pdf) pattern (keys in LSM, values in separate log).

**Implication**: compaction touches *only the index*, not the arenas. This is huge for our case — the arenas are mmapped and never rewritten. Merging L0→L1 rewrites ~40M × (8 key + 8 offset + 4 fingerprint + 1 n_actions + 2 epoch) = ~920MB. A leveled-compaction RocksDB-style merge would also rewrite the float arenas (5+ GB at f32).

**Implication for layer ordering**: when we compact L0+L1 into a new L1', the old L0 and L1 arena slots are now **garbage** (the new L1' has fresh offsets into a fresh arena segment, OR the offsets still point at the old arena slots which are now stable).

This is where the user's "delete-by-overwrite in flat mmap" question lives — covered next.

---

## 6. Can we delete-by-overwrite in flat mmap arenas without dangling references?

**Short answer: no, not safely during a live read.** Long answer:

The dangling-reference risk has two layers:

**(a) Within a frozen layer's lifetime**: if L0 says `key=K → offset=42` and you overwrite slot 42 in the arena with new data before deleting K from L0, then a reader looking up K reads garbage.

Solution: **never overwrite arena slots while any frozen layer still references them**. The frozen layer is immutable; its references are immutable. On compaction, the new layer either:
- Keeps the same offset (if the entry survived merge unchanged) — fine
- Allocates a new arena slot (if the entry was merged with another) — old slot becomes a hole

**(b) Holes accumulate**: this is now a garbage-collection problem. Two clean ways to handle it:

1. **Arena per generation**. Each batch of frozen layers gets its own arena segment. When all layers referencing arena segment N are compacted away, you `munmap` + `unlink` segment N. No hole-tracking needed. This is the BookKeeper / Kafka log-segment pattern and the [Pebble](https://github.com/cockroachdb/pebble) value-block pattern.

2. **Bump allocator + periodic copying GC**. Compaction rewrites surviving entries into a new arena and atomically swaps the mmap. Readers hold a generation counter; old arena is unmapped after all readers drain.

Option 1 is simpler and fits the periodic-freeze cadence. Pick that.

**Concrete rule: never overwrite a live arena slot. Allocate a new slot in a new arena segment during compaction; mark the old segment for deletion once all referencing layers are gone.** This is the "log-structured everything" discipline; WiscKey calls it the vLog garbage collection ([WiscKey paper section 4.2](https://pages.cs.wisc.edu/~ll/papers/wisckey.pdf)).

---

## 7. Compaction stalls — how to keep writers from blocking readers

RocksDB has explicit write-stall machinery because compaction can fall behind random write streams ([RocksDB Write Stalls wiki](https://github.com/facebook/rocksdb/wiki/Write-Stalls)). We are not write-stall constrained — our writes are periodic and bounded.

The real risk for us is **read-stall during freeze**: when a worker thread is in the middle of building a new frozen layer (MPHF construction is ~50 ns/key × 10M keys = 500 ms per L0 layer with BBHash), other threads must not block on accessing the in-flight layer.

Patterns to copy:

1. **Single-writer, multi-reader with atomic publish**. Build the new frozen layer in a temp file. When MPHF is built and arrays are sealed, atomically swap a pointer (Arc, ArcSwap, or epoch-based reclamation). Readers see either the old layout or the new layout — never a half-built one. RocksDB uses `Version` objects for this; the Pebble crate calls it the `versionSet`.

2. **Lock-free layer list using `arc-swap`** in Rust. Cost: one atomic load per lookup at the layer-list root. Reader steady-state is wait-free.

3. **Defer munmap to a reclamation thread**. After publishing the new layer set, the old layers' arenas can't be unmapped until all in-flight readers complete. Epoch-based reclamation (crossbeam-epoch) or a generation counter handles this.

4. **Decouple MPHF construction from main reader threads**. Don't build the MPHF on a reader thread holding any lock. Build it on a dedicated compaction thread; readers continue probing the old layer set throughout. Even if the new layer takes 5s to build, readers see no stall.

The combination above gives **zero blocking time** for readers during freeze. This is the single most important property for us.

---

## 8. Read amplification budget

How many layers should we probe before it's "too many"?

Numbers:
- Single MPHF query: ~50 ns (BBHash, [paper Section 5](https://arxiv.org/pdf/1702.03154))
- Single Bloom probe (full filter): ~30 ns (one cache miss)
- Single ribbon probe: ~120 ns (paper measures 3-4× Bloom CPU but better cache, [RocksDB Ribbon](https://rocksdb.org/blog/2021/12/29/ribbon-filter.html))
- Mmap arena offset deref: ~80 ns (one DRAM cache miss on a cold key)

At 8 lookups/iter × 4000 iters/sec aggregate = 32K lookups/sec. Budget per lookup: ~31 μs aggregate, ~1 μs per thread.

With 5 layers and our recommended geometry:
- 1 hot map probe: ~30 ns
- 4 frozen layers, each: 50 ns MPHF + 80 ns arena = 130 ns × 4 = 520 ns
- Bloom prefilter on layers 3,4 cuts cold-key cost in half: ~360 ns

Total: ~400 ns hot, ~600 ns cold. Within budget by 1-2 orders of magnitude. **5 layers is fine. 8 layers would still be fine. Don't sweat read amp until you see it in perf.**

This is where [Monkey](https://daslab.seas.harvard.edu/monkey/) is most useful: it formalizes that lookup cost ≈ Σ FPR_i across all probed layers, and that you should allocate more filter bits to *deeper* layers because they're probed more often when the key is absent. For us: spend the bits where it matters (L2+); leave L0 with just the fingerprint.

---

## 9. Things to explicitly reject

- **LevelDB/RocksDB BlockBasedTable format**: 4KB blocks with sparse index ([Cassandra docs](https://docs.scylladb.com/architecture/sstable/sstable3/sstables_3_index/), [LevelDB sparse index](https://justlike.medium.com/modern-databases-sparse-index-in-leveldb-part-3-69f50d72e24f)) is great for range scans and bad for hash-keyed point lookups. We already have direct MPHF-to-offset mapping; we'd be regressing.
- **Universal compaction (RocksDB)**: similar size-tiered shape but bundles in fence-pointer/block-index machinery we don't need. Just take the geometry idea.
- **PebblesDB FLSM with guards**: guards partition by key range. Hash-keyed lookups don't benefit; we'd pay range-tracking overhead for zero gain.
- **B-epsilon trees (SplinterDB)**: range-friendly hybrid. Reject — overkill complexity for point lookups.
- **Bourbon learned indices**: learn the CDF of keys to predict offsets. For hashed keys, the CDF is uniform random — there's nothing to learn. Reject.
- **Ribbon at L0**: paper itself says ribbon is for layers living >1 hour ([RocksDB Ribbon blog](https://rocksdb.org/blog/2021/12/29/ribbon-filter.html)). L0 in our setup lives ~minutes between freezes. Stick to Bloom at shallow layers.
- **Per-key Bloom in front of MPHF for shallow layers**: redundant with fingerprint; net loss.

---

## 10. Concrete sketch of our specific LSM structure

```
LayerStack (atomic Arc-swapped):
  ┌─────────────────────────────────────────────────────────────┐
  │  HotOverflow: FxHashMap<u64, CompactEntry>                  │  per-thread, heap
  │  L0 layers: [FrozenLayer; ≤4]                               │  mmapped, 10M ea
  │  L1 layers: [FrozenLayer; ≤4]                               │  mmapped, 40M ea
  │  L2 layers: [FrozenLayer; ≤4]                               │  mmapped, 160M ea
  │  L3 layers: [FrozenLayer; ≤4]                               │  mmapped, 640M ea
  │  L4 layer: FrozenLayer                                      │  mmapped, 2.5B+
  │  Arenas: [ArenaSegment; gen]                                │  mmapped f32 floats
  └─────────────────────────────────────────────────────────────┘

FrozenLayer (mmap layout, header + 5 fixed-stride arrays):
  ┌─────────┬────────────────┬────────────────────┐
  │ Header  │ MPHF (BBHash)  │ Fingerprint[u32]   │
  │         │ ~3.7 bits/key  │ 4 bytes/key        │
  ├─────────┴────────────────┴────────────────────┤
  │ Offset[u64]   4 bytes/key (or u32 if <4G)     │
  │ NActions[u8]  1 byte/key                      │
  │ Epoch[u16]    2 bytes/key                     │
  ├───────────────────────────────────────────────┤
  │ Bloom/Ribbon filter (L2+ only) 4-10 bits/key  │
  └───────────────────────────────────────────────┘

Lookup algorithm (per query):
  1. Hot map probe   → if hit, return (typical ~30 ns)
  2. For layer in newest-to-oldest:
     a. If layer has Bloom/Ribbon: probe; if absent → next layer
     b. slot = layer.mphf.query(key)                  → ~50 ns
     c. if layer.fingerprint[slot] != hash32(key):     return None
     d. return (layer.offset[slot], layer.nactions[slot], layer.epoch[slot])
  3. If no layer hit → uninitialized info set

Freeze trigger (per thread):
  - When HotOverflow exceeds ~10M entries, build L0 frozen layer:
    1. Sort keys (optional, only if you want range debugging)
    2. Build BBHash MPHF with γ=2 (3.7 bits/key, ~500ms for 10M keys)
    3. Allocate fingerprint, offset, nactions, epoch arrays
    4. Insert entries into MPHF-mapped slots
    5. msync; atomically publish via arc-swap
    6. Drop HotOverflow contents (or clear in-place)

Compaction trigger (background thread):
  - When count of layers at level L ≥ 4: merge them into L+1.
  - Build new arena segment for surviving entries.
  - Build new MPHF over the union of keys.
  - Publish; mark old arenas+layers for delayed reclamation (after epoch advance).

Concurrency:
  - Readers: arc-swap load → atomic snapshot of layer list. No locks.
  - Writers (freeze/compact): build in temp space, publish atomically.
  - Reclamation: crossbeam-epoch or generation-counter delayed unmap.
```

**Expected steady state for 1B info sets**: ~5 GB index (10 bytes/key × 1B + 4 bits MPHF + filters), ~256-512 GB arenas (regret + strategy at f32, 6 bytes/action × 4 actions × 1B keys ≈ 24 GB per arena, ×2). Index fits comfortably in OS page cache.

**Expected steady state for 10B**: ~50 GB index, ~480 GB arenas at f32 or ~240 GB at bf16. With ε=15 the unique info-set count is bucketed harder so 5-7B is more realistic — still fits a 1TB box.

---

## 11. Quick answers to your specific questions

1. **Do we need bloom filters per layer if our MPHF differentiates known vs unknown?**
   No — MPHF does not differentiate; add a 32-bit fingerprint at each MPHF slot instead. Add a small Bloom (4-bit) only on deep, cold layers (L2+) to skip the MPHF probe entirely on cold-key misses.

2. **What's the right L0/L1/L2 size ratio?**
   Size-tiered with fanout 4, 4 layers per level. 10M / 40M / 160M / 640M / 2.5B. Reject the 10× leveled fanout (designed for random writes).

3. **Sort layers by recency or hash range?**
   Recency. Newest-first probe with early-exit on hit. Hash-range sorting is for range queries.

4. **Can we delete-by-overwrite in flat mmap arrays without dangling references?**
   No — never overwrite live arena slots. Use arena-per-generation: compaction writes survivors to a new arena segment; old segment is unmapped once no layer references it. Atomic swap + epoch-based reclamation.

5. **Per-layer fingerprints as alternative to full keys?**
   Yes — 32-bit fingerprint per slot is the sweet spot for u64 keys. FPR ≈ 2^-32, one cache-line load. Strictly better than 10-bit Bloom for our access pattern.

6. **Read amplification budget?**
   5 layers easily fits in our ~1 μs/lookup/thread budget. Don't optimize until measured.

7. **Compaction stalls?**
   Reader stalls = the only stall that matters. Build new layers on a dedicated thread; publish via arc-swap. Defer munmap via epoch-based reclamation. Zero blocking on reader threads.

---

## Sources

- [Sarkar et al., Constructing and Analyzing the LSM Compaction Design Space, VLDB 2021](https://vldb.org/pvldb/vol14/p2216-sarkar.pdf)
- [Dayan, Athanassoulis, Idreos, Optimal Bloom Filters and Adaptive Merging for LSM-Trees (Monkey), TODS 2018](https://cs-people.bu.edu/mathan/publications/tods18-dayan.pdf)
- [Dayan et al., Monkey: Optimal Navigable Key-Value Store](https://daslab.seas.harvard.edu/monkey/)
- [Lu et al., WiscKey: Separating Keys from Values in SSD-conscious Storage, FAST 2016](https://pages.cs.wisc.edu/~ll/papers/wisckey.pdf)
- [Limasset et al., Fast and scalable minimal perfect hashing for massive key sets (BBHash), SEA 2017](https://arxiv.org/pdf/1702.03154)
- [BBHash GitHub](https://github.com/rizkg/BBHash)
- [boomphf Rust crate (10x Genomics)](https://10xgenomics.github.io/rust-boomphf/master/boomphf/hashmap/index.html)
- [Dillinger, Ribbon filter: practically smaller than Bloom and Xor, arXiv 2021](https://arxiv.org/pdf/2103.02515)
- [RocksDB Ribbon Filter blog post](https://rocksdb.org/blog/2021/12/29/ribbon-filter.html)
- [RocksDB Bloom Filter wiki](https://github.com/facebook/rocksdb/wiki/RocksDB-Bloom-Filter)
- [RocksDB Tuning Guide](https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide)
- [RocksDB Write Stalls wiki](https://github.com/facebook/rocksdb/wiki/Write-Stalls)
- [RocksDB BlockBasedTable Format](https://github.com/facebook/rocksdb/wiki/Rocksdb-BlockBasedTable-Format)
- [RocksDB Universal Compaction wiki](https://github.com/facebook/rocksdb/wiki/Universal-Compaction)
- [RocksDB Dynamic Level Size blog](https://rocksdb.org/blog/2015/07/23/dynamic-level.html)
- [Raju et al., PebblesDB: Fragmented LSM, SOSP 2017](https://dl.acm.org/doi/pdf/10.1145/3132747.3132765)
- [Conway et al., SplinterDB, ATC 2020](https://splinterdb.org/)
- [Dai et al., From WiscKey to Bourbon: a learned index for LSM, OSDI 2020](https://www.usenix.org/system/files/osdi20-dai_0.pdf)
- [Fan et al., Cuckoo Filter: Practically Better Than Bloom, CoNEXT 2014](https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf)
- [ScyllaDB SSTables 3.0 Index File Format](https://docs.scylladb.com/architecture/sstable/sstable3/sstables_3_index/)
- [ScyllaDB SSTables 3.0 Summary File Format](https://docs.scylladb.com/manual/stable/architecture/sstable/sstable3/sstables-3-summary.html)
- [Bender et al., PtrHash: Minimal Perfect Hashing at RAM Throughput, SEA 2025](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.SEA.2025.21)
- [DASlab Compactionary visualization](https://disc-projects.bu.edu/compactionary/background.html)
- [Scavenger: Space-Time Tradeoffs for KV-Separated LSM-trees, arXiv 2025](https://www.arxiv.org/pdf/2508.13909)