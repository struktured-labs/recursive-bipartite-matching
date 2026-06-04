Ignoring task reminders — this is review work, no implementation. I have enough data to deliver the verdict.

---

# Build-vs-Buy Reality Check

## 1. Library reality check

| Library | Claimed | Verified |
|---|---|---|
| **PtrHash (`ptr_hash`)** | "MIT, SEA 2025, 2.4 bits/key, 8.7ns warm, epserde mmap" | **EXISTS, mostly accurate.** v1.1.0 (Mar 2025) MIT. 2.0.0-alpha.1 (Sep 2025) is current bleeding edge. `epserde` is **opt-in feature, not default**. 1B-key benchmarks are on integer keys with default params; `default_compact()` has "lowered reliability" per docs. No documented construction failures, but also no documented success-rate guarantees. **Verdict: real, but "soak test before committing" is appropriate, not optional.** |
| **`memmap2`** | "11K+ reverse deps, sensible choice" | **CONFIRMED.** v0.9.10 Feb 2026, MIT/Apache, 11,191 crates use it. Already a dep in your Cargo.toml. |
| **`arc-swap`** | "canonical Rust wait-free read primitive" | **CONFIRMED.** v1.9.1 April 2026, MIT/Apache, 9,500+ reverse deps. |
| **`crossbeam-epoch`** | "production-tested, Rust-native deferred munmap" | **EXISTS but inaccurately characterized.** v0.9.18 Jan 2024 — actually 2 years stale, not "recent." `Guard::defer()` exists but the docs explicitly warn: *"there is no guarantee when exactly f will be executed"* and `defer_destroy()` is the intended path for heap objects, not arbitrary destructors like `munmap`. Using it for deferred unmap is workable but needs care; the proposal slightly oversells how clean this is. |
| **`xorf`** | "ribbon/xor filters, MIT, maintained 2025, ~7 bits/key ribbon" | **PARTIALLY WRONG.** v0.12.0 Aug 2025, MIT — confirmed. **xorf does NOT implement ribbon filters.** It provides Xor8/16/32 and BinaryFuse8/16/32. Binary Fuse is a close cousin of ribbon (~9 bits/key for BinaryFuse8, similar fast-membership semantics) but it's not the ribbon construction the proposal name-checks. **No maintained Rust ribbon-filter crate exists** in the search results. If you want ribbon specifically, you'd port it yourself; if you accept Binary Fuse, xorf works. The "7 bits/key" number is also off — BinaryFuse8 is ~9.1 bits/key. |
| **`bytemuck`** | "saves a lot of unsafe" | **CONFIRMED.** v1.25.0 Jan 2026. Already a dep. |
| **`rustc-hash`** | "FxHashMap (already used)" | **CONFIRMED.** v2.1.2 Mar 2026. Already a dep. |
| **`hashbrown`** | "Rust's SwissTable port, already used" | **CONFIRMED.** v0.17.1 May 2026. |
| **`epserde`** | "convenient mmap deserialization" | **EXISTS but ARCHITECTURAL CONFLICT.** v0.12.6 Apr 2026, Apache OR LGPL-2.1+. Pulls in `mmap-rs` as a transitive dependency — a **different crate from `memmap2`**. Your codebase already uses `memmap2` for `MmapArena`. Adopting PtrHash's epserde feature drags in a second mmap crate that does not interoperate with `memmap2` types. Either both coexist (wasted code + risk of subtle interaction) or you migrate `MmapArena` to `mmap-rs`. Not addressed by the proposal. |
| **`boomphf`** | "migrate away — PtrHash beats it" | **STRAWMAN.** Your codebase does not use `boomphf`. It uses `ph::fmph::GOFunction` (FMPHGO from the `ph` crate, v0.11.0 Feb 2026, MIT/Apache, actively maintained, ~2.1 bits/key). The proposal's "migrate from boomphf" framing is wrong. The real comparison is `ph::fmph::GOFunction` (~2.1 bits/key) vs PtrHash (~2.4 bits/key). **PtrHash is LARGER, not smaller, than what you have today.** PtrHash's claim to fame is query speed (8.7 ns warm), not storage. The "1-2 bits/key savings" claim in Phase 2 is **backwards** — switching from FMPHGO to PtrHash *costs* you 0.3 bits/key. |
| **`left-right`** | implicitly named in "left-right (Ramalhete) pattern using arc-swap" | **CONFUSING.** `left-right` and `arc-swap` are **different primitives**, not one wrapping the other. `left-right` v0.11.7 Dec 2025 maintained, is the Ramalhete-pattern implementation. `arc-swap` is RCU-style atomic Arc swap. You'd pick one. The proposal conflates them. |
| **`libnuma`** (Rust binding) | "set_mempolicy(MPOL_INTERLEAVE) at startup" | **DEEPLY STALE.** `libnuma` crate v0.0.4, **last release June 2017**, Rust 2015 edition, "obsolete" deps flagged. `libnuma-sys` is also v0.0.4 from same era. You'd either vendor it, write a tiny syscall wrapper yourself (~50 LOC), or shell out to `numactl` at process launch. Proposal hand-waves this. |

## 2. Custom-code reality check

| "We'll write ourselves" | Claimed effort | Honest estimate |
|---|---|---|
| **File format / header / on-disk layout** | "Build, domain-specific, bytemuck cast" | **~300–500 LOC** for a single layer (header, magic, version, byte-offset tables, alignment, endian decisions, fingerprint/payload section descriptors, mmap'd reader struct + serde to disk). Realistic. |
| **Freeze / compaction logic** (single layer only) | "Build, domain-specific" | **~400–700 LOC.** Your existing `frozen_state.rs` is 485 LOC for the *no-fingerprint, no-multi-layer* version. Adding fingerprint write/read + version tag + atomic file publish is +150–200 LOC on top. |
| **Size-tiered LSM with fanout 4, 5 layers, compactor thread** | "1-2 weeks" | **Closer to 3–4 weeks of focused work, plus 1–2 weeks of stress-test bake.** This is the hard one. You're writing: (a) layer-stack manifest, (b) compactor thread + scheduling policy + back-pressure, (c) merge logic that visits k layers and emits 1 layer at the next level, (d) atomic publish + crash-safe manifest swap, (e) interaction with the writer (epoch handoff), (f) the arena-per-generation invariant, (g) reclamation hook + crossbeam-epoch wiring, (h) lookup path that probes newest-first with early-exit + per-layer prefilter. Realistic LOC: **1,500–2,500 lines of new code**, mostly tricky, mostly in places where a single off-by-one corrupts the on-disk index. The "1-2 weeks high risk" estimate is **about 2x optimistic** for a careful engineer; with the stress-test debug mode the proposal itself describes, you're at 4–6 weeks. |
| **Arena-per-generation** | "transient overhead" | **~600–1000 LOC** to retrofit `MmapArena`. Your current arena is one-file-grows-forever (367 LOC). Splitting into generations means: (a) generation manifest, (b) per-generation file lifecycle, (c) offset translation across generations (your `regret_offset: u64` now needs a generation tag — that's a u64 layout change, breaking every existing checkpoint), (d) reclamation, (e) safe migration of in-flight readers. The "never overwrite live slot" invariant the proposal calls out airtight is exactly the bug surface. |
| **NUMA glue** | "set_mempolicy at startup" | **~50–150 LOC** plus deciding whether to vendor `libnuma-sys`. Trivial if you just call `numactl --interleave=all` from a wrapper script. Real Rust impl is small but the testing matrix (single-socket vs dual-socket vs CCD-only EPYC) adds time. |
| **Hugepages + mlock + prefetch batching** | "1 week, low-medium risk" | **~200–400 LOC** of `madvise` calls, `mlock`, `_mm_prefetch` intrinsics. Realistic if you have a profiler ready and a benchmark suite. The "batch 8 prefetch then 8 lookups" pattern is straightforward to add to the lookup API, hard to A/B against the current path without microbenches. |
| **Cold-tier prefilter wrapper** | "Buy xorf" | **xorf doesn't have ribbon.** You either accept BinaryFuse (~9 bits/key, not 7) or write ribbon yourself (300+ LOC of construction + serialization). |
| **Left-right OR arc-swap of hot map** | "wait-free reader semantics" | **`left-right` crate handles WriteHandle/ReadHandle correctly out of the box** for a single-writer FxHashMap if you wrap as an `Absorb` impl (~100–200 LOC trampoline). `arc-swap` of `Arc<FxHashMap>` is simpler (~30 LOC) but you pay a full-map clone on every freeze — at 10M entries × 32 threads that's a 5GB transient hit, not free. **Pick one and stop conflating them.** |
| **Stress-test harness** ("debug mode that fills old generation with poison bytes, 24-hour fuzz") | listed as part of Phase 4 | **~500–1000 LOC of test infrastructure** + 24h calendar wallclock. Not included in the 1–2 week Phase 4 estimate. |

**Total custom code: ~3,500–5,500 LOC** of new Rust, vs. the proposal's "~3-4K lines." Their lower bound is reachable only if size-tiered LSM is descoped to "second frozen layer" and arena-per-generation is descoped. Their estimate is roughly accurate at the *low* end of scope, **substantially low** for the full proposed scope.

## 3. Effort estimate honesty check (per phase)

| Phase | Proposal estimate | Honest estimate |
|---|---|---|
| **Phase 1 — Fingerprint at MPHF slot** | 2–3 days, low risk | **3–5 days realistic.** Touches frozen_state.rs (485 LOC), file format version bump, checkpoint load path (795 LOC of checkpoint.rs), all existing tests, and you must validate on a 100M+ key sample. Low risk *if* you don't break existing checkpoints. **Accurate-ish at the optimistic end.** |
| **Phase 2 — PtrHash migration** | 3–5 days, medium risk | **5–10 days realistic, possibly negative payoff.** PtrHash is 0.3 bits/key *worse* than the FMPHGO you're using today. The justification "smaller-MPHF storage story we need at 10B scale" is **factually wrong** vs your current stack. The real reason to migrate is query speed (~2× faster) and the epserde mmap story (load without rebuilding the MPHF on startup). epserde drags in mmap-rs which conflicts with memmap2 — that's a half-week of dep reconciliation the proposal omits. |
| **Phase 3 — Left-right / arc-swap publish** | 4–5 days, medium risk | **7–14 days realistic.** Concurrency correctness is unforgiving. The proposal's own "stress test 1M lookups/sec across 32 threads during synthetic freeze" is a *test artifact you also have to build*. The wrapper-around-`FxHashMap` for left-right is the `Absorb` impl — non-trivial because every insert must be replayable on the other side. Picking `arc-swap` instead means full clone on swap, which the proposal claims is "~160 MB × 32 = 5 GB transient" — that's a per-freeze 5 GB allocation spike that may push you past memory limits at scale. **Accurate at midpoint of estimate, optimistic at low end.** |
| **Phase 4 — Size-tiered compaction + arena-per-generation** | 1–2 weeks, high risk | **4–8 weeks realistic.** This is the load-bearing phase and the most under-estimated. New code: layer manifest, compactor scheduling, k-way merge of layer probes into one, arena generation tracking, offset-tag refactor (breaks checkpoint format), crossbeam-epoch integration for deferred munmap, atomic manifest publish under crash semantics. Plus the stress-test mode. The proposal's own description says "high blast radius" and "24-hour fuzz test" — those don't fit in 2 weeks even on the optimistic schedule. **Single biggest realism gap in the plan.** |
| **Phase 5 — Ribbon prefilter + NUMA + hugepages + prefetch** | 1 week, low-medium risk | **2–3 weeks realistic.** Ribbon doesn't exist in xorf — that's an extra 3–5 days to port or an architecture-change to accept BinaryFuse. NUMA libs are stale; you're vendoring or writing your own. Prefetch batching is straightforward but needs benchmarks to validate. Hugepage `mlock` of the deepest layer's ctrl+fingerprint arrays requires you to know layer sizes statically. **Accurate at the upper end of estimate; optimistic at the low end.** |

**Total honest estimate: 12–22 weeks (3–5.5 months)** of focused engineering for the full proposed scope, vs. the proposal's implied **5–7 weeks**. That's a 2–3× under-estimate.

## 4. Final verdict

### Buildable in claimed time (low scope-risk)
- **Phase 1 (fingerprint) — yes**, possibly +2 days. Highest ROI per LOC. Independently shippable. **Do this first regardless of the rest.**
- **Phase 5 sub-items: prefetch batching + MADV + hugepages — yes** as a separate 1-week effort once you have stable layers to instrument. NUMA glue is its own ~3 days.

### Buildable but mis-justified (re-scope the rationale, not the work)
- **Phase 2 (PtrHash migration)** — the *storage* justification is wrong (PtrHash is +0.3 bits/key vs. your current `ph::fmph::GOFunction`). The real justification is query speed and mmap-time load. Decide whether the 2× lookup speedup matters more than (a) adding a dep with mmap-rs/memmap2 conflict, (b) 2.0.0-alpha churn on the bleeding-edge PtrHash. Honest cost: 1.5–2 weeks, not 3–5 days.
- **Phase 3 (left-right vs arc-swap)** — pick exactly one, don't say "left-right wrapped using arc-swap" (those are different things). For a single-writer FxHashMap, `left-right` v0.11 is the right tool; budget 1.5–2 weeks including stress-test scaffolding.

### Needs re-scoping (the plan as written is too ambitious for the time stated)
- **Phase 4 (size-tiered LSM + arena-per-generation)** is **the load-bearing phase and the most under-estimated.** Decompose into:
  - 4a: just add a *second* frozen layer with stack-of-2 lookup (1.5–2 weeks)
  - 4b: arena-per-generation, no compaction, no reclamation (1.5–2 weeks)
  - 4c: compactor thread + size-tiered merge + crossbeam-epoch reclamation (3–4 weeks + 1–2 week soak)
  - Net: ~8 weeks not "1–2 weeks." If you can defer 4c to "after 1B works," do so — your current evals are landing at 1B without it.

### Reject outright
- **xorf as ribbon prefilter** — xorf doesn't have ribbon. Substitute BinaryFuse8 (~9 bits/key, not 7) or write ribbon yourself. The proposal's "Buy xorf for ~7 bits/key ribbon" is factually wrong on both library and storage number.
- **"Migrate away from boomphf"** — you're not on boomphf. You're on `ph::fmph::GOFunction`. Adjust framing.
- **`libnuma` Rust crate** — stale since 2017. Either vendor `libnuma-sys` (~50 LOC wrapper) or invoke `numactl --interleave=all` from launch wrapper. The proposal under-specs this.
- **The "left-right wrapped using arc-swap" formulation** — those are alternative primitives, not composable layers. Choose one.

### Open questions the proposal lists that are actually blockers, not curiosities
- **Q1 (PtrHash construction at 1B with your key distribution)**: Decision-critical for Phase 2. PtrHash's `default_compact()` has documented reliability degradation. Your u64 keys derived from `hash(RBM bucket + board bucket + betting history)` are uniform if hashed properly, but PtrHash's paper benchmarks used uniform-random integers, not domain-derived hashes. Empirical soak required before committing.
- **Q3 (ribbon vs Bloom prefilter)**: Moot — neither ships in xorf as ribbon. Re-frame as "BinaryFuse vs custom Bloom vs no prefilter."
- **Open Q's 6, 7 (RBP pruning, dense betting-history)**: Correctly scoped out. These are genuinely orthogonal.

### Bottom line
The architecture is *directionally sound* — fingerprint at MPHF slot, point-lookup-only index, mmap-backed flat arrays, WiscKey-style value separation, single-writer multi-reader frozen layers. The library choices are mostly real but contain three factual errors (xorf ribbon, boomphf migration, PtrHash being smaller than current stack) and one dependency conflict (epserde mmap-rs vs your memmap2) that need correction before the plan is actionable. The effort estimates are realistic for Phase 1, optimistic by ~2× for Phases 2/3/5, and optimistic by ~3–4× for Phase 4. Ship Phase 1 in week 1, then decide whether Phase 4 is worth the calendar cost or whether you can keep stacking frozen layers without size-tiered compaction until you actually hit 5B+ scale and need it.

### Sources

- [ptr_hash crate (lib.rs)](https://lib.rs/crates/ptr_hash)
- [PtrHash paper, SEA 2025](https://drops.dagstuhl.de/storage/00lipics/lipics-vol338-sea2025/LIPIcs.SEA.2025.21/LIPIcs.SEA.2025.21.pdf)
- [PtrHash arxiv 2502.15539](https://arxiv.org/abs/2502.15539)
- [PtrHash GitHub](https://github.com/RagnarGrootKoerkamp/PtrHash)
- [ph crate (FMPHGO/FMPH/PHast)](https://lib.rs/crates/ph)
- [boomphf crate](https://lib.rs/crates/boomphf)
- [arc-swap crate](https://lib.rs/crates/arc-swap)
- [left-right crate](https://lib.rs/crates/left-right)
- [memmap2 crate](https://lib.rs/crates/memmap2)
- [mmap-rs crate](https://lib.rs/crates/mmap-rs)
- [epserde crate](https://lib.rs/crates/epserde) (transitively pulls mmap-rs)
- [crossbeam-epoch Guard docs](https://docs.rs/crossbeam-epoch/latest/crossbeam_epoch/struct.Guard.html)
- [xorf crate](https://lib.rs/crates/xorf) (Xor + BinaryFuse only; no ribbon)
- [xorf GitHub](https://github.com/ayazhafiz/xorf)
- [bytemuck crate](https://lib.rs/crates/bytemuck)
- [rustc-hash crate](https://lib.rs/crates/rustc-hash)
- [hashbrown crate](https://lib.rs/crates/hashbrown)
- [odht crate (Rust compiler team, last release 2021)](https://lib.rs/crates/odht)
- [libnuma Rust binding (last release 2017)](https://lib.rs/crates/libnuma)
- [Steve Hanov on MPHF false-positive behavior on absent keys](https://stevehanov.ca/blog/throw-away-the-keys-easy-minimal-perfect-hashing)
- [Existing frozen_state.rs in this repo](file:///home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/frozen_state.rs)
- [Existing mmap_arena.rs in this repo](file:///home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/mmap_arena.rs)
- [Existing Cargo.toml](file:///home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/Cargo.toml)