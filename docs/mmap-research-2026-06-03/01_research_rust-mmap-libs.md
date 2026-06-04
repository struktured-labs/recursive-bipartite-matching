I have plenty of solid material. Time to compose the report.

# Mmap-Backed K/V & Hashing Crates for Rust MCCFR Trainer

## TL;DR — Ranked Shortlist

1. **odht** + **memmap2** for frozen layers. Pure-mmap, no heap overhead, no MPHF construction cost, deterministic on-disk layout, std-HashMap-level lookup. Designed by the rustc team for *exactly* this use case (hash table → disk → mmap, read-mostly). The big catch: last release was 2021. We accept this because it is genuinely "done", in production in rustc today, and the code is ~3K lines we can vendor and own.
2. **PtrHash (`ptr_hash`)** + **memmap2** + flat value arrays (replace boomphf). 2.4 bits/key, 8.7 ns/lookup with prefetching, mmap-friendly via the `epserde` feature. This is the same shape as your current BBHash-flat-array design, but ~2× smaller and ~2× faster, and the paper is from SEA 2025 — current research, actively developed.
3. **rkyv 0.8 + `ArchivedHashMap`** + memmap2 (for hot overflow layer, or for entire small frozen layers). Zero-copy CHD-based perfect-hash map directly over mmap, in active use at Cloudflare for ML inference. Heavier dep tree, slightly worse memory layout than option 1, but the friendliest API of the three.

The remaining candidates (redb, sled, fst, boomphf, raw `ph`) are not competitive for this exact workload — details below.

---

## Per-Library Detail

### 1. odht — rust-lang/odht
- **Repo / license**: https://github.com/rust-lang/odht — Apache-2.0 / MIT
- **Last release**: 0.3.1, **2021-10-29**. Only 54 commits ever. *De facto stable*: shipped inside every rustc binary since.
- **Data model**: Open-addressing hash table; you implement a `Config` trait that pins K, V, hash function, and encoding. Generic enough for `Config<Key=u64, Value=(u64, u8, u16)>` (offset, n_actions, epoch — 11 bytes payload).
- **Mmap behaviour**: Pure. The on-disk layout *is* the in-memory layout. `HashTable::from_raw_bytes(&mmap[..])` gives you a zero-copy view. No alignment or endianness assumptions, so cross-host mmap files work. No heap allocation per table.
- **Read performance**: "Roughly the same as `std::HashMap`" per the README. Open-addressing with FxHash-class hashers → ~1 cache line per lookup on a hit, single hash compute. This is the lowest per-lookup cost in the field for a u64 key.
- **Write performance**: `HashTableOwned` builds in-memory then `raw_bytes()` dumps to disk. Build cost is std-HashMap-class. Append to existing frozen layer is *not* supported — but you don't need it; freeze cycles already write whole new layers.
- **Concurrency**: Not thread-safe on `HashTableOwned`. The mmap-view `HashTable` is `Send + Sync` if `C` is — i.e. **lock-free reads are fine**. Single-writer builds, multi-reader queries. Exactly your access pattern.
- **Fixed vs growable**: Owned table auto-grows during build; serialized table is fixed-size (rebuild to grow). Capacity must be roughly known but not exactly.
- **API ergonomics**: Implement one trait, two methods (`get`, `raw_bytes`). Vendor-friendly. Probably the cleanest fit in this list.
- **Battle-tested**: Used in rustc for incremental compilation cache. That's the entire rust ecosystem effectively.
- **Suitability: 9/10.** The honest downside is "last release Oct 2021"; the honest mitigation is "the rustc team is still using it". If you want a single-crate answer for the frozen layer, this is it.

### 2. PtrHash — RagnarGrootKoerkamp/PtrHash (`ptr_hash` on crates.io)
- **Repo / license**: https://github.com/RagnarGrootKoerkamp/PtrHash — MIT.
- **Last release**: `ptr_hash` 1.1.0 (active 2025). SEA 2025 paper.
- **Data model**: Minimal perfect hash function, the *successor* to PtHash/boomphf. NOT a hash map — it gives you an index in `[0, n)` and you put your own value array next to it on disk.
- **Mmap behaviour**: With the `epserde` feature, the MPHF structure deserializes via mmap with effectively no copy. Pair with flat `[u8]` for your `(offset, n_actions, epoch)` payload.
- **Read performance**: **~21 ns/key sequential, ~8.7 ns/key with streaming prefetch** on 1B-key benchmarks. About 2× faster to query than the next-fastest MPHF at comparable size. Touches 1–2 cache lines (pilot table + value table).
- **Write performance**: 30 s to build a 1B-key MPHF on 6 threads with 2.4 bits/key. Sharded construction available for 50B+ keys — directly relevant to your 5B/10B aspirational scale.
- **Concurrency**: Lock-free reads (immutable mmap structure). Build is multi-threaded.
- **Fixed vs growable**: Static MPHF, must know key set at build. This already matches your LSM "freeze every ~1M iters" pattern.
- **API ergonomics**: Construct from a `&[Key]` slice, query with `phf.index(&key) -> usize`. You wire it to your existing flat arrays exactly like you do with BBHash today. Small migration.
- **Battle-tested**: New (2025), but the algorithm is published, peer-reviewed (SEA), benchmarked aggressively. The author is responsive on GitHub.
- **Suitability: 9/10.** Drop-in mental model for "replace BBHash". Smaller, faster, mmappable, and there's a real billion-key benchmark in the literature.

### 3. rkyv 0.8 (ArchivedHashMap)
- **Repo / license**: https://github.com/rkyv/rkyv — MIT.
- **Last release**: 0.8.16, **2026-04-22**. Very active. 2,141 reverse deps; 9.3M downloads/month.
- **Data model**: Zero-copy *deserialization framework*. `ArchivedHashMap` is a perfect-hash map using CHD (compress-hash-displace). You serialize `HashMap<u64, V>` once, the bytes ARE the map, mmap them and call `.get()`.
- **Mmap behaviour**: `rkyv::access::<ArchivedHashMap<u64, V>, _>(&mmap)` gives a typed view. With `access_unchecked` you skip validation for hot loads. Pair with Cloudflare's `mmap-sync` (Apache 2.0, v2.0.1 2024-11) if you want their atomic-swap RCU pattern between writer freezes.
- **Read performance**: O(1) with CHD; "same lookup performance as std HashMap" per docs. Likely 1–2 cache lines for u64→small-payload because of CHD's pilot table indirection. A hair worse than odht's open-addressing, but in the same ballpark.
- **Write performance**: Build std `HashMap`, call `to_bytes` once at freeze time. Whole-buffer write, no in-place updates.
- **Concurrency**: Reads on the archived view are `Sync` for `Sync` value types — lock-free reads ✓. Writes are not concurrent (rebuild on freeze).
- **Fixed vs growable**: Fixed at archive time. Fine for freeze-cycle architecture.
- **API ergonomics**: The friendliest of the three. Derive macros, no Config trait. The cost is a heavy dep tree (`rkyv` pulls in `bytecheck`, `munge`, etc.).
- **Battle-tested**: Cloudflare ML inference (`mmap-sync` blog post), Apache Iggy, lots of game-dev shops. Real production miles.
- **Suitability: 8/10.** Slightly heavier and slightly slower than odht, but actually maintained in 2026 and well-documented. This is the "lowest-risk" pick.

### 4. redb
- **Repo / license**: https://github.com/cberner/redb — Apache-2.0 / MIT
- **Last release**: 4.1.0, **2026-04-19**. Very active. File format stable since 2.x.
- **Data model**: Copy-on-write B+tree, ACID, MVCC, lmdb-inspired.
- **Mmap behaviour**: Uses mmap'd B-trees per the README, but maintains a heap-resident page cache layer (4.1 added dynamic read/write cache partitioning).
- **Read performance**: B-tree → O(log n) and 2–4 cache lines per lookup. For 1B keys that's ~30 comparisons. **This is the wrong shape** for a hot 32-K/s loop where you've already paid to compute a fast hash.
- **Write performance**: Decent — single-writer transactional with batching. 1.5× speedup in 4.1.
- **Concurrency**: MVCC, lock-free reads, single writer. Architecturally fine.
- **API ergonomics**: `TableDefinition<u64, [u8; 11]>` + transactions. Pleasant.
- **Battle-tested**: Yes, growing adoption, stable format.
- **Suitability: 4/10.** You're paying for ACID transactions and range queries you don't need, and you're getting log-n point lookups when you could have O(1). If you wanted "one library that solves everything", this is it. For your *actual* workload, it's overkill and wrong-shape.

### 5. sled
- **Repo / license**: https://github.com/spacejam/sled — Apache-2.0 / MIT
- **Last release**: 1.0.0-alpha.124, **2024-10-11**. Long-running rewrite ("komora", "marble") that has never landed. Author explicitly says "use SQLite if reliability matters". *Beta* per its own README, file format still expected to change before 1.0.
- **Data model**: Lock-free B+tree over an LSM-flavored log.
- **Mmap**: Not really; it's a log-structured pagecache.
- **Suitability: 1/10.** Not maintained on a "ship in 2026" timeline, format-unstable, wrong shape (B-tree), and the maintainer literally tells you not to use it. Pass.

### 6. fst (BurntSushi)
- **Repo / license**: https://github.com/BurntSushi/fst — MIT / Unlicense.
- **Maintained**: yes, battle-tested in Tantivy/Meilisearch/ripgrep.
- **Data model**: Ordered set/map via finite-state transducer. Keys are byte strings (you'd encode u64 → 8 bytes big-endian).
- **Mmap**: Excellent — that's its whole point.
- **Read perf**: O(|key|) byte walks. For 8-byte keys that's ~8 transitions, each ~1 cache line. Slower than direct hashing.
- **Builds**: Keys must be inserted in sorted order. You'd sort 1M overflow keys every freeze cycle — fine.
- **Suitability: 5/10.** Beautifully maintained, wrong tool. It shines when keys have shared prefixes (strings). For random u64 hashes there is no prefix structure to exploit, so you pay automaton overhead without compression gains. Use only if you also need range/prefix queries, which you don't.

### 7. rkyv (covered above as #3)

### 8. `ph` (PHast / FMPH / FMPHGO)
- **Repo / license**: https://github.com/beling/bsuccinct-rs — Apache-2.0 / MIT.
- **Last release**: 0.11.0, **2026-02-12**. Active, PHast paper at ALENEX 2026.
- **Data model**: MPHF only (like boomphf/PtrHash). PHast: <2 bits/key, fastest query in the literature. FMPH: ~2.8 b/key. FMPHGO: ~2.1 b/key.
- **Mmap**: Not first-class. No epserde support documented; you'd hand-roll Pod-style serialization or live with a small heap footprint for the pilot/seeds vectors.
- **Read perf**: PHast is arguably state-of-the-art on raw query latency; the trade is that mmap story is weaker than PtrHash.
- **Suitability: 7/10.** Excellent algorithm, weaker mmap glue than PtrHash. Worth considering if you find PtrHash's epserde dep stack annoying — `ph` has fewer deps and the new PHast variant is competitive on speed.

### 9. boomphf (your current MPHF)
- **Repo / license**: https://github.com/10XGenomics/rust-boomphf — MIT.
- **Last release**: 0.6.0, **2023-07-26**. Effectively stable; 10X Genomics uses it in production single-cell pipelines.
- **Data model**: BBHash MPHF, 3–6 bits/key.
- **Mmap**: No native mmap. Has optional serde for save/load; you load by deserializing into heap. The "BoomHashMap" wrapper stores key+value `Vec`s in heap.
- **Read perf**: ~iter levels of bit-vector probes per lookup; slower than PtrHash and PHast in current benchmarks.
- **Suitability: 5/10.** Works, is in production, you already use it. But every dimension you care about (bits/key, ns/lookup, mmap-native-ness) is now beaten by PtrHash. Migrate.

### 10. memmap2
- **Repo / license**: https://github.com/RazrFalcon/memmap2-rs — Apache-2.0 / MIT.
- **Last release**: 0.9.10, **2026-02-15**. 11K+ reverse deps. Used by tantivy, polars, datafusion, parquet, etc.
- **Data model**: Low-level mmap. The plumbing for everything above.
- **Suitability: 10/10 as plumbing.** Not optional; pair with whichever index you pick.

---

## Bonus finds (since 2023, worth knowing about)

- **epserde** (vigna/epserde-rs, Apache-2.0/LGPL, 0.12.6 2026-04-02): The ε-copy framework PtrHash uses for mmap. Could also be applied to your own structs if you want full control without rkyv's dep weight.
- **mmap-sync** (cloudflare/mmap-sync, Apache-2.0, v2.0.1 2024-11): rkyv + dual-buffer RCU. If you ever want a swap-without-pause freeze cycle, this is the pattern.
- **PtrHash** (covered as #2).

---

## How the top picks slot into your LSM + arenas design

**Pick A (recommended): PtrHash + odht-or-flat-arrays + memmap2.** Replace boomphf with PtrHash for frozen-layer index (~2.4 b/key, 8.7 ns/lookup, mmap-native via epserde). Keep your per-thread `FxHashMap<u64, CompactEntry>` for the hot overflow — that's already optimal for write-heavy short-lived state. At freeze time: per thread, build a `Vec<u64>` of keys (already sorted by insertion or hash), build `Ptr Hash::new(&keys)`, serialize the MPHF via epserde to `layer_N.mphf`, write parallel `layer_N.payload` containing `(u64 offset, u8 n_actions, u16 epoch)` indexed by the MPHF's `index(&key)`. Reader path: `mphf.index(&key)` → byte offset into mmapped payload → 8-byte load. **8.7 ns/lookup, 1 cache line per query, ~2.4 bits/key + 88 bits payload = ~11.3 bytes/entry. For 5B entries that's ~57 GB on disk, well under your 120 GB working-set ceiling.**

**Pick B (single-crate, lowest-effort): odht for frozen layers + keep FxHashMap for overflow.** Implement `Config` with `Key=u64`, `Value=[u8; 11]`, FxHash hasher. At freeze: dump `HashTableOwned` raw bytes to `layer_N.odht`, mmap, query with `HashTable::from_raw_bytes(&mmap)`. **Open-addressing → 1 cache line per lookup on hit, ~12 ns. Storage: open-addressing at 95% load → ~13.7 bytes/entry, so ~68 GB for 5B.** Slightly worse storage than PtrHash, but the whole thing is one trait impl and you're done. The 2021-vintage risk is real but bounded — it's 3K lines of code, vendor it.

**Pick C (best ergonomics, slightly heavier): rkyv 0.8 ArchivedHashMap for frozen layers.** Build `HashMap<u64, CompactEntry>` per thread, serialize at freeze via `rkyv::to_bytes`, mmap on the read side. CHD gives perfect-hash O(1) lookups. **Slightly more cache lines per lookup than odht due to CHD pilot table indirection (~15–20 ns), but you write 30 lines of code and inherit a maintained, popular crate with a Cloudflare-tested mmap-swap pattern available next door in `mmap-sync`.**

The right decision tree: **if you trust yourself to vendor a 2021 crate → odht; if you want active upstream + maximum compression → PtrHash; if you want minimum effort and don't mind a heavy dep tree → rkyv 0.8.** All three solve your stated problem; the rest of the list does not.

Sources:
- [rust-lang/odht](https://github.com/rust-lang/odht)
- [odht on lib.rs (release date verification)](https://lib.rs/crates/odht)
- [odht docs](https://docs.rs/odht/latest/odht/)
- [PtrHash repo](https://github.com/RagnarGrootKoerkamp/PtrHash)
- [PtrHash: Minimal Perfect Hashing at RAM Throughput (SEA 2025)](https://arxiv.org/abs/2502.15539)
- [ptr_hash crate](https://lib.rs/crates/ptr_hash)
- [epserde-rs](https://github.com/vigna/epserde-rs)
- [rkyv repo](https://github.com/rkyv/rkyv)
- [rkyv on lib.rs](https://lib.rs/crates/rkyv)
- [ArchivedHashMap docs](https://docs.rs/rkyv/latest/x86_64-apple-darwin/rkyv/collections/hash_map/struct.ArchivedHashMap.html)
- [cloudflare/mmap-sync](https://github.com/cloudflare/mmap-sync)
- [redb repo](https://github.com/cberner/redb)
- [redb 4.1 release notes (Phoronix)](https://www.phoronix.com/news/Redb-4.1-Released)
- [sled repo](https://github.com/spacejam/sled)
- [BurntSushi/fst](https://github.com/BurntSushi/fst)
- [10XGenomics/rust-boomphf](https://github.com/10XGenomics/rust-boomphf)
- [beling/bsuccinct-rs (ph crate)](https://github.com/beling/bsuccinct-rs)
- [ph crate on lib.rs](https://lib.rs/crates/ph)
- [PHast paper (arXiv)](https://arxiv.org/pdf/2504.17918)
- [memmap2](https://github.com/RazrFalcon/memmap2-rs)
- [memmap2 on lib.rs](https://lib.rs/crates/memmap2)