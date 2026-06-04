I have enough data to write the deep-dive. Let me compose the final response.

# Deep Dive: C/C++ Key-Value Stores with Rust Bindings for MCCFR LSM Index

## Workload TL;DR
We need a u64 → (u64 offset, u8 n_actions, u16 epoch) map at 1B–10B entries, 32 readers × 8 lookups/iter, batched writes per ~1M-iter freeze, mmap-friendly, <120GB working set at 10B aspirational scale.

Headline finding: **most "store" libraries below are over-engineered for this workload**. RocksDB/LevelDB/Sled all carry transaction + range-query + WAL overhead we will pay for and never use. The two C/C++ contenders that actually fit are **LMDB (via heed)** and **libmdbx (via libmdbx-rs)**. For pure in-memory hot-tier, no C/C++ hash map has a maintained Rust binding worth the FFI tax — Rust's hashbrown is already a SwissTable port of abseil and dominates.

---

## Candidate-by-Candidate

### 1. LMDB via `heed`  -- RECOMMENDED
- **Name + binding + repos**: LMDB (OpenLDAP), Rust crate `heed` (v0.22.1, 2026-04-07). https://github.com/meilisearch/heed , https://github.com/LMDB/lmdb
- **License**: LMDB = OpenLDAP Public License (BSD-style, permissive). heed = MIT.
- **Last release**: heed 0.22.1, April 7, 2026. Actively maintained by the Meilisearch team.
- **Data model + mmap**: B+tree over a single mmap-ed file. Reads are pointer-arithmetic into the mmap — zero-copy `&[u8]` returned to the caller. Single-writer, MVCC for readers. This is its core selling point.
- **Read/write perf**: Reads are essentially the cost of an LMDB B+tree walk against page cache. Production single-threaded reads are ~5-10M lookups/sec; at 32 threads it linearly scales because reader txns are lock-free MVCC snapshots. Writes are serialized through a global write lock — fine since we only freeze every ~1M iters.
- **Concurrency**: Single-writer multi-reader, exactly our pattern. Reader threads do not block each other.
- **Build complexity**: heed bundles LMDB C source via `lmdb-master-sys`. No system lib needed; `cargo build` works. Adds ~150KB to the binary.
- **Battle-tested**: Meilisearch (search engine), Mozilla (Firefox sync via `rkv`), Monero, Reth (pre-MDBX), Cuprate. Years of production at high QPS.
- **Risk**: LMDB DB size is capped by the mapped region. You set `map_size` at open and it can't grow past `MDB_MAP_RESIZED`-without-reopen. At 5–10B entries, sizing math: entry overhead ~16-20 bytes raw + LMDB B+tree ~32B amortized ≈ 320GB at 10B. That works on EPYC with 256GB RAM only as cold mmap; you'd want NVMe and the page cache as your working set. **The hard answer**: LMDB shines if you compact key+value to ~16 bytes and use `MDB_INTEGERKEY` + `MDB_APPEND` on sorted freeze batches. Hot cache stays in RAM, cold stays paged on NVMe — exactly LMDB's design point.
- **Suitability: 9/10**

### 2. libmdbx via `libmdbx-rs`  -- STRONG SECOND
- **Name + binding + repos**: libmdbx (Erigon/Reth fork+rewrite of LMDB), Rust crate `libmdbx` v0.6.6 (2026-02-04). https://github.com/vorot93/libmdbx-rs , https://gitflic.ru/project/erthink/libmdbx
- **License**: libmdbx = OpenLDAP Public License. libmdbx-rs = MPL-2.0. MPL is OK for static linking (file-level copyleft, not viral).
- **Last release**: 0.6.6, Feb 4, 2026. ~32K downloads/month, used by Reth Ethereum client.
- **Data model + mmap**: Same as LMDB (B+tree over mmap) with several improvements: automatic map-size growth, faster bulk-load, better write amplification, smaller readers table.
- **Read/write perf**: Benchmarked ~10-30% faster than LMDB on writes, comparable on reads, better at large dataset sizes.
- **Concurrency**: Single-writer multi-reader, same as LMDB.
- **Build complexity**: Bundles C source. Builds clean. ~3K lines Rust + C deps. Requires a working C compiler.
- **Battle-tested**: Reth (Paradigm's Ethereum execution client) handles multi-terabyte state DBs in production. Erigon (Ethereum) was the original driver.
- **Risk**: MPL-2.0 binding may trip your SIG IP review if they care about file-level copyleft; LMDB+heed is cleaner there. Also the upstream maintainer (Leonid Yuriev) had drama with GitHub and moved the canonical repo off it; binding still works fine but upstream tracking lags slightly.
- **Suitability: 8.5/10** (would be #1 if not for MPL + slightly less stable upstream hosting)

### 3. RocksDB via `rocksdb` crate
- **Name + binding + repos**: RocksDB (Facebook), Rust crate `rust-rocksdb` (the published `rocksdb` crate). v0.24.0, 2025-08-10. https://github.com/rust-rocksdb/rust-rocksdb
- **License**: RocksDB = GPLv2 OR Apache-2.0 (dual). rust-rocksdb = Apache-2.0.
- **Last release**: 0.24.0 Aug 2025, with active branches (a fork at `zaidoon1/rust-rocksdb` releases faster; tracks RocksDB master).
- **Data model + mmap**: LSM tree, not mmap-first. RocksDB *has* `BlockBasedTableOptions::allow_mmap_reads`, but it's been deprecated/discouraged for years — the canonical reader uses pread + BlockCache.
- **Read/write perf**: Read amplification is bad for our access pattern. Bloom filters help but each lookup walks multiple SSTs. For 32K lookups/sec we'd pay ~2-5 SST seeks per lookup. RocksDB needs sustained writes to be worth its complexity, and we have batched-only writes.
- **Concurrency**: Excellent multi-reader-multi-writer. Overkill for us.
- **Build complexity**: HEAVY. Builds RocksDB C++ from source (~5min on first build), pulls Snappy/LZ4/zstd/zlib/bzip2 unless feature-disabled, requires clang+cmake+libstdc++. CI footprint balloons.
- **Battle-tested**: Everywhere — Meta, TiKV, CockroachDB, Solana validators.
- **Risk**: We will fight RocksDB's defaults (tune block cache, disable compression, tune WAL) for a workload it wasn't designed for. The mmap-read path is also buggy historically (Facebook themselves recommend pread).
- **Suitability: 4/10** — wrong tool for batch-write-once / point-read-many.

### 4. LevelDB via `leveldb` / `rusty-leveldb`
- **Name + binding + repos**: LevelDB (Google), `leveldb` crate (FFI to libleveldb) or `rusty-leveldb` (pure-Rust port by dermesser). https://github.com/skade/leveldb (binding), https://github.com/dermesser/leveldb-rs (port)
- **License**: LevelDB = BSD-3. `leveldb` crate = MIT. `rusty-leveldb` = MIT.
- **Last release**: The `leveldb` FFI crate is essentially abandoned (~2020 last meaningful update). `rusty-leveldb` has occasional updates but no 2026 release.
- **Data model + mmap**: LSM tree, pread-based, no real mmap.
- **Read/write perf**: Single-threaded only on writes. Worse than RocksDB on every axis. No reason to pick this over RocksDB.
- **Build complexity**: Needs `libleveldb-dev` system package for the FFI crate.
- **Risk**: **REJECT** — binding is unmaintained. RocksDB strictly dominates if you want an LSM at all.
- **Suitability: 2/10** — REJECTED as abandoned binding.

### 5. libcuckoo
- **Name + binding + repos**: libcuckoo (CMU). https://github.com/efficient/libcuckoo . Only Rust attempts: `pythonesque/libcuckoo.rs` (a 4-commit port, dormant since 2015) and `datenlord/lockfree-cuckoohash` (independent Rust impl, not a binding).
- **License**: libcuckoo = Apache-2.0.
- **Last release**: libcuckoo upstream last meaningful tag 2019, sporadic commits since. No maintained Rust binding exists.
- **Data model + mmap**: Pure in-memory concurrent hash table. **No persistence, no mmap.**
- **Concurrency**: Fine-grained locking, excellent multi-threaded writes.
- **Risk**: **REJECT** — no maintained Rust binding. In-memory only. Even if we wanted to FFI it ourselves, hashbrown (Rust's SwissTable) is faster on modern x86 and is in std.
- **Suitability: 1/10** — REJECTED, no binding + wrong shape (pure in-memory).

### 6. Google sparsehash (sparse_hash_map / dense_hash_map)
- **Name + binding + repos**: https://github.com/sparsehash/sparsehash . Rust binding: there is no maintained one. `rustyx/sparsehash` shows up but is essentially dead.
- **License**: BSD-3.
- **Last release**: 2.0.4, August 2020. Upstream basically frozen.
- **Data model + mmap**: In-memory. `sparse_hash_map` has a `write_metadata` / `read_metadata` snapshot API but it's an explicit serialize step, not live mmap.
- **Risk**: **REJECT** — no maintained Rust binding; upstream frozen; the entire selling point ("2 bits/entry overhead") is moot when our value record is 11+ bytes.
- **Suitability: 1/10** — REJECTED.

### 7. Abseil flat_hash_map / SwissTable
- **Name + binding + repos**: https://github.com/abseil/abseil-cpp . **No maintained Rust binding.** Rust's `hashbrown` (and therefore `std::collections::HashMap`) is *literally* a Rust port of SwissTable.
- **Risk**: **REJECT** — using FFI to call abseil from Rust gets us nothing over `hashbrown::HashMap` (or `FxHashMap`, which we already use). Whatever you'd gain is lost across the FFI boundary.
- **Suitability**: N/A for FFI — but recognize hashbrown is already what we'd get. **Use `hashbrown` directly**, do not FFI.

### 8. Facebook Folly F14
- **Name + binding + repos**: https://github.com/facebook/folly . No Rust binding.
- **License**: Folly = Apache-2.0.
- **Data model**: In-memory 14-way chunked hash table. Two SSE2 probes per lookup.
- **Risk**: Building Folly from a Rust project is ~30min of pain (Boost, fmt, gflags, glog, double-conversion all required). Even if you write FFI shims, you trade hashbrown's already-tuned probing for Folly's slightly-different SIMD probing — single-digit-percent at best, and you eat C++ ABI ownership churn.
- **Suitability: 2/10** — Build burden vastly exceeds upside.

### 9. Bonus: maintained Rust-native alternatives we found while searching
- **redb** (cberner, MIT/Apache-2.0, v4.1.0 Apr 2025+, mmap-based B-tree, pure Rust). Strong dark-horse: ACID + mmap + no C deps. Worth a benchmark but probably 1.5-2x slower than LMDB on cold reads.
- **sled** (spacejam, Apache-2.0/MIT). Author has explicitly said don't use it for new projects; "1.0 perpetually upcoming." **REJECT.**
- **sanakirja** (Pijul VCS, GPL/MPL). Niche, B-tree on mmap. License + ecosystem concerns.
- **persy** (single-file transactional). Wrong shape — adds WAL we don't need.
- **boomphf / ph / minimal_perfect_hash**: For your *frozen layer MPHF*, these are the live alternatives to your hand-rolled BBHash. `minimal_perfect_hash` (Aug 2025, MIT) explicitly supports "dump to disk and mmap on startup for instant cold starts" — slot-in compatible with your design.

---

## Top-2 Integration Sketches

### Top pick: LMDB via `heed` — replaces the entire LSM stack

Your current design has two tiers: hot `FxHashMap<u64, CompactEntry>` per thread + frozen LSM layers. LMDB collapses both.

```rust
// Cargo.toml
heed = { version = "0.22", default-features = false, features = ["lmdb"] }

// At trainer init
use heed::{EnvOpenOptions, Database, types::*};

let env = unsafe {
    EnvOpenOptions::new()
        .map_size(400 * 1024 * 1024 * 1024)  // 400GB virtual; OS pages as needed
        .max_dbs(2)
        .max_readers(64)                      // ≥ 32 threads
        .flags(heed::EnvFlags::NO_SYNC | heed::EnvFlags::NO_META_SYNC)
        .open("/data/mccfr/lmdb")?
};

let mut wtxn = env.write_txn()?;
// Use INTEGER_KEY so LMDB does memcpy comparisons on u64 keys (zero hash work).
let entries: Database<U64<NativeEndian>, Bytes> =
    env.create_database(&mut wtxn, Some("entries"))?.with_integer_key();
wtxn.commit()?;

// Read path (per reader thread, held across many iters)
let rtxn = env.read_txn()?;  // MVCC snapshot, lock-free
for &key in iter_keys {
    match entries.get(&rtxn, &key)? {
        Some(bytes) => {
            // bytes is &[u8] pointing directly into mmap — zero copy
            let offset = u64::from_ne_bytes(bytes[0..8].try_into().unwrap());
            let n_actions = bytes[8];
            let epoch = u16::from_ne_bytes(bytes[9..11].try_into().unwrap());
            // ... do MCCFR step
        }
        None => { /* new info-set path */ }
    }
}
// rtxn dropped at scope end; refresh with env.read_txn() every ~10K iters
// so you observe new freeze batches.

// Freeze path (single writer, every ~1M iters)
let mut wtxn = env.write_txn()?;
// MDB_APPEND requires sorted keys — pre-sort the hot map by key.
let mut hot_sorted: Vec<_> = hot_map.drain().collect();
hot_sorted.sort_unstable_by_key(|(k, _)| *k);

let mut writer = entries.iter_mut(&mut wtxn)?;
for (key, entry) in hot_sorted {
    let mut buf = [0u8; 11];
    buf[0..8].copy_from_slice(&entry.offset.to_ne_bytes());
    buf[8] = entry.n_actions;
    buf[9..11].copy_from_slice(&entry.epoch.to_ne_bytes());
    // Use put with MDB_APPEND-equivalent for sorted bulk insert (≥10x faster)
    entries.put_with_flags(&mut wtxn, heed::PutFlags::APPEND, &key, &buf)?;
}
wtxn.commit()?;
```

Why this works for our specific shape:
- The hot `FxHashMap` per-thread tier disappears: LMDB read txns are essentially free (no lock, no copy). The 8 lookups/iter become 8 mmap pointer chases.
- The frozen-layer LSM disappears: LMDB is one B+tree, no compaction, no merging across layers.
- BBHash MPHF disappears: LMDB's B+tree handles the lookup.
- Sizing: with `MDB_INTEGERKEY` + 11-byte value, on-disk entry is ~28 bytes amortized → 280GB at 10B, ~140GB at 5B, ~28GB at 1B. EPYC + NVMe handles all three; the 256GB box happily holds 5B as warm pages.
- Crash durability: with `NO_SYNC | NO_META_SYNC` we batch fsync at freeze boundaries via `env.force_sync()`. Matches the "no durability beyond msync" constraint.

### Top alt: libmdbx via `libmdbx-rs` — same code shape, better growth

If you want the same model but with automatic map growth (no `400GB` declaration up-front), swap heed for libmdbx-rs. The API is nearly identical:

```rust
// Cargo.toml
libmdbx = { version = "0.6", features = ["with-bench"] }

use libmdbx::{Environment, NoWriteMap, DatabaseFlags};

let env = Environment::<NoWriteMap>::new()
    .set_geometry(libmdbx::Geometry {
        size: Some(0..4 * 1024_usize.pow(4)),  // up to 4TB, grows as needed
        growth_step: Some(8 * 1024_usize.pow(3)),
        shrink_threshold: None,
        page_size: Some(libmdbx::PageSize::Set(16384)),
    })
    .open("/data/mccfr/mdbx")?;

let txn = env.begin_rw_txn()?;
let db = txn.create_db(Some("entries"), DatabaseFlags::INTEGER_KEY)?;
txn.commit()?;

// Read+write identical to LMDB pattern above.
```

Pick libmdbx-rs over heed if: you can't predict max DB size up-front, you want explicit growth control, or you're already comfortable with MPL-2.0. Pick heed if: you want the most-mature LMDB binding, MIT license, and the largest production track record (Meilisearch).

---

## Rejection Summary
- **LevelDB binding** (`leveldb` crate): abandoned binding. Reject.
- **libcuckoo Rust binding** (`libcuckoo.rs`): 4-commit dead port from 2015, no real binding. Reject.
- **sparsehash Rust binding**: no maintained binding, upstream frozen 2020. Reject.
- **Abseil flat_hash_map FFI**: pointless — hashbrown is the Rust port. Use hashbrown.
- **Folly F14 FFI**: heavy build (Boost/gflags/glog/fmt), no binding, marginal upside. Reject.
- **sled**: author-disrecommended. Reject.

---

## Recommendation
1. **Replace** per-thread `FxHashMap` + LSM frozen layers + custom BBHash MPHF with **LMDB via heed** (or libmdbx via libmdbx-rs). Single B+tree on mmap. Code surface shrinks ~3x.
2. **Keep** the f32/bf16 regret + strategy arenas as raw mmap files keyed by `offset` from LMDB. Don't put arena data inside LMDB — it'd defeat zero-copy in the inner loop.
3. **Bench** redb in parallel as a pure-Rust fallback. If it's within 30% of LMDB read latency, the simpler build + no FFI may be worth the small perf hit; if it's 2x slower, stick with LMDB.
4. **Do not** FFI any in-memory C/C++ hash map. Rust's `hashbrown::HashMap` and `FxHashMap` are already at or above the perf of abseil/F14/libcuckoo for our key shape (u64).

Sources:
- [heed (crates.io)](https://docs.rs/crate/heed/latest)
- [heed (GitHub)](https://github.com/meilisearch/heed)
- [LMDB upstream](https://github.com/LMDB/lmdb)
- [libmdbx-rs (GitHub)](https://github.com/vorot93/libmdbx-rs)
- [libmdbx on Lib.rs](https://lib.rs/crates/libmdbx)
- [rust-rocksdb](https://github.com/rust-rocksdb/rust-rocksdb)
- [rocksdb crate (docs.rs)](https://docs.rs/crate/rocksdb/latest)
- [zaidoon1/rust-rocksdb fork](https://github.com/zaidoon1/rust-rocksdb)
- [leveldb-rs (rusty-leveldb)](https://github.com/dermesser/leveldb-rs)
- [efficient/libcuckoo](https://github.com/efficient/libcuckoo)
- [pythonesque/libcuckoo.rs (dormant)](https://github.com/pythonesque/libcuckoo.rs)
- [datenlord/lockfree-cuckoohash](https://github.com/datenlord/lockfree-cuckoohash)
- [Google sparsehash](https://github.com/sparsehash/sparsehash)
- [Abseil flat_hash_map](https://github.com/abseil/abseil-cpp/blob/master/absl/container/flat_hash_map.h)
- [Folly F14 announcement](https://engineering.fb.com/2019/04/25/developer-tools/f14/)
- [folly/F14.md](https://github.com/facebook/folly/blob/main/folly/container/F14.md)
- [redb](https://github.com/cberner/redb)
- [redb releases](https://www.redb.org/)
- [boomphf](https://github.com/10XGenomics/rust-boomphf)
- [minimal_perfect_hash crate](https://crates.io/crates/minimal_perfect_hash)
- [ph crate](https://lib.rs/crates/ph)
- [sled](https://github.com/spacejam/sled)
- [mozilla/lmdb-rs (INACTIVE)](https://github.com/mozilla/lmdb-rs)
- [Up to date Rust LMDB bindings (HN)](https://news.ycombinator.com/item?id=41678228)