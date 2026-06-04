That's enough — the existing trainer is **per-thread state** (no sharing), with periodic single-threaded freeze. The proposal moves to **shared frozen layers across all 32 readers** with concurrent freeze. That's a much harder concurrency model. Now let me write the adversarial review.

---

# Adversarial Review: MCCFR Index Architecture Proposal

**Default position: the proposal is broken until each claim is verified.** Below is what I found.

## 1. Showstoppers (must fix before any code lands)

### H1. "Wait-free multi-reader via left-right alternation" on a per-thread map is incoherent
**Severity: showstopper.** Section 2, "Layer 0 — Hot overflow (per-thread)".

The proposal writes: *"`FxHashMap<u64, CompactEntry>` (existing), wrapped in a left-right (Ramalhete) pattern using `arc-swap` so 32 readers see a wait-free consistent view during freeze."*

Three independent problems here:

1. **The current design is per-thread, so "32 readers" is fiction at L0.** L0 is the owning thread's own map. There is no cross-thread reader to be wait-free for. If the proposal is silently switching L0 from per-thread to shared, that change destroys the existing trainer's only good property (no per-lookup synchronization on the 99.99% of lookups that hit the hot tier). The proposal never owns up to this. Either way, the claim is wrong.
2. **Left-right and `arc-swap` are not the same primitive.** Ramalhete's Left-Right requires two physical copies maintained in lockstep by the writer, plus a per-reader epoch register. `arc-swap` is plain RCU — single shared snapshot, atomic swap. They have very different memory profiles. The "+1 hot map per thread during freeze window (~160 MB × 32 = 5 GB transient)" budget in Phase 3 is the arc-swap budget; left-right would be **2×** always-resident, not transient — 320 MB × 32 = 10 GB steady-state. Pick one.
3. **The map type listed (`FxHashMap`) is `!Sync` for mutation.** You cannot legally have one thread call `find_or_add` (which Rusts's borrow rules require `&mut`) while another thread holds a `&` reference through an `Arc` — even if the writer-thread is the only writer, the reader side will racily observe partially-written control bytes, partially-resized capacity, and partially-written entries. `arc-swap` does not fix this: the snapshot a reader sees is a `&FxHashMap` whose interior is being mutated under a `&mut` alias the writer is using. This is **immediate UB**, not "racy but mostly fine."

**Minimum fix:** drop the "left-right" framing entirely. Either (a) keep L0 per-thread and have the freeze copy the snapshot first under `&mut` from the owning thread, then publish the *frozen layer* (not the hot map) via `ArcSwap<LayerStack>`; or (b) move to a real concurrent map (`dashmap`, `papaya`) at the L0 tier and accept its per-lookup cost. There is no middle ground.

### H2. Arena-per-generation reclamation via `crossbeam-epoch` cannot prove no in-flight reader is using the arena
**Severity: showstopper.** Section 2, "Layer 2 — Value arenas" + Phase 4.

The proposal: *"When all layers referencing segment N are compacted away, `munmap` + `unlink` segment N."* Implemented via `crossbeam-epoch` deferred munmap.

`crossbeam-epoch` pins a *guard* on a per-thread basis. The guard tracks that **the calling thread is inside a critical section**. The reclamation policy fires once all threads have advanced past the pinning epoch.

What the proposal does not address: **a reader doing the index lookup pins under the new generation's arena pointer (because the new `ArcSwap<LayerStack>` is already published) but then resolves the `u64 offset` against the *old* arena it cached from the prior snapshot.** The pin only guards the structure the reader entered the critical section with — but in this architecture readers carry around `u64 offset` values that index **into a separate arena file** chosen by which generation the entry came from. The reader has to keep the *old* arena's mmap alive until the offset is dereferenced. `crossbeam-epoch` does not see "this thread is still using arena segment N because it has a CompactEntry whose offset references segment N." You have to bundle the arena handle with the entry, or extend the guard to cover both the index and the arena, or carry the arena's `Arc` through every `regret(entry, i)` call.

A worked-out failure scenario:
- Reader on T1 calls `lookup(key)` → gets back `entry { regret_offset = 0x4000_0000, arena_gen = 7 }`.
- Reader holds the entry on its stack, walks down the MCCFR recursion to a sibling subtree, comes back.
- Meanwhile T_freeze finishes compaction → new layer published, gen-7 arena now has zero referencing layers, T_freeze's epoch advances past T1's pin (because T1 is between subtree recursions and is not currently pinned).
- T_freeze `munmap`s gen-7 arena.
- T1 returns to the parent call, calls `state.regret(&entry, 0)` → SIGSEGV.

The proposal calls this out as *"the dangling-reference invariant must be airtight"* and proposes *"a debug mode that fills the old generation with poison bytes immediately on reclaim"*. That's catching it after the fact. The architecture itself has no story for **how the invariant is established by construction**.

**Minimum fix:** every `CompactEntry` (or the `ArcSwap<LayerStack>` snapshot) must own an `Arc<ArenaSegment>` for each generation it references. Drop the "arena-per-generation with epoch reclamation" claim and replace with `Arc`-counted segments — at the cost of an atomic refcount per lookup. Or: forbid `munmap` until the freeze coordinator runs a barrier through *all* worker threads (rayon's `join` + a generation counter the workers check at iteration boundaries).

### H3. `FrozenCfrState::find_or_add` requires `&mut self` and writes to the *frozen* arena
**Severity: showstopper.** Verified in `frozen_state.rs:152-189, 222-262`.

The current frozen state's `find_or_add` does an in-place write to `self.epochs[slot]` for lazy DCFR (line 206) **on every lookup that crosses an epoch boundary**. `add_regret`, `set_regret`, `add_strategy` (lines 222-262) all `&mut self.regret_arena`. The hot path is mutating, not read-only.

The proposal's whole concurrency story rests on *"Read-only post-publish. Atomic `Arc<LayerStack>` swap"*. The codebase says this is false for the current data structure: **the frozen layer mutates its arena at runtime**.

If the proposal intends to redesign the frozen layer to truly be read-only, then either:
- Per-lookup epoch comparisons must move to a separate, per-thread mutable side-table (defeats the cache-line claim — now reads touch a 4th cache line), or
- Every per-action regret/strategy write must go through an `AtomicI16`/`AtomicU32` (regrets and strategy sums are stored as `f32` — `AtomicF32` doesn't exist in stable Rust, you bit-cast through `AtomicU32`, every read is a relaxed-ordered load, and the SIMD inner loop in `regret_matching` becomes scalar), or
- Writes funnel through the freeze coordinator as a separate WAL replayed at the next freeze (massive design change — Phase 4 doesn't describe this).

The proposal silently assumes "frozen = immutable" while the existing frozen path is mutable. **Phase 2 (PtrHash migration) will compile and pass the test in `test_freeze_and_lookup` and then deadlock or corrupt at 32-thread runtime.**

**Minimum fix:** explicitly redesign all mutating frozen paths. Spell out which arena slots become atomic, which mutations move to a per-thread side-table merged at freeze, and which (lazy DCFR? regret accumulation? strategy accumulation?) require a different access pattern entirely. Until that is on paper, Phase 4 is hand-waving.

### H4. PtrHash + `epserde` does not let the writer rebuild while readers are mid-lookup
**Severity: showstopper.** Section 2 + Phase 2.

The proposal says *"Replace `boomphf::Mphf` with `ptr_hash::PtrHash` for newly-built frozen layers"* and claims `arc-swap` makes the publish wait-free.

The story is fine for **already-built** layers being swapped in. It is broken for the **build itself**. PtrHash construction at 1B keys (per the proposal's own footnote) takes minutes — `fmph::GOFunction::from_slice(&all_keys)` in `frozen_state.rs:64` already takes 30-60s for 1B per the comment, and PtrHash with epserde is in the same ballpark. During those minutes:

- The owning thread is `&mut` on its hot overflow (collecting keys).
- The reader threads are walking the old layer stack.
- New keys arriving in the owning thread go… where? The proposal does not say. Phase 3 says *"reader threads never block"* but says nothing about *new writes* to the thread's own hot map while the freeze is in flight.

If the writer-thread's hot map is being copied into the MPHF, and the writer-thread is also still running MCCFR iterations and writing new entries, **the snapshot the freeze coordinator is hashing is a moving target**. Either:
- The MCCFR worker thread pauses during freeze (kills your "zero reader blocking" claim — the worker is *also* a reader),
- A second hot overflow is kept open for new writes during the freeze window (now you really do have two hot maps per thread + atomic swap — 320 MB × 32 + transient freeze copy = 15 GB peak, not the 5 GB the proposal claims),
- Or new writes go into a different per-thread shard that gets merged later (substantial design change — not described).

**Minimum fix:** specify "freeze owns the prior map, new map is created empty and is the new write target; old map is read-only from this instant onward". This is the actual left-right pattern, and it costs 2× hot-tier memory steady-state — line up the budget table accordingly.

### H5. `crossbeam-epoch` deferred munmap is the wrong primitive for `MAP_SHARED` files
**Severity: likely bug → showstopper at 10B scale.** Section 2 + Phase 4.

`crossbeam-epoch`'s defer-drop runs on the next `pin`'s collector cycle, which can fire **on a reader thread's CPU during a lookup hot path**. If `Drop for MmapSegment` calls `munmap` + `unlink`, you've just done a syscall on the lookup hot path that took your TLB hostage for the duration. With 32 threads, all going through 8 lookups/iter, freezes occasionally landing the munmap drop on a worker mid-iteration → unpredictable tail latency.

Worse: the proposal also says `MADV_DONTNEED` on superseded layers. `MADV_DONTNEED` on a `MAP_SHARED` file is **the documented Linux footgun** — it zeroes anonymous mappings and forces re-fault on file-backed ones. On the next reader access to a "superseded" region (which can happen because the layer-stack swap and the madvise are not atomic w.r.t. readers), you eat a hard page fault per cache line. At 32K lookups/sec with non-trivial fault rates, this caps you at I/O.

**Minimum fix:**
- Move `munmap`/`unlink` off the lookup path. Use a dedicated reclamation thread that pulls from a queue; readers only push retired layer handles.
- Drop `MADV_DONTNEED` from the design. Use `MADV_FREE` (anonymous pages only — irrelevant here) or do nothing and let the kernel evict; the page cache works fine for the read-heavy workload described.

## 2. Likely bugs (will hit in stress test)

### M1. Fingerprint check requires 1 cache line even on miss — the "shallow layers" claim is wrong
**Severity: likely bug (perf, not correctness).** Section 2: *"32-bit fingerprint at the MPHF slot strictly dominates Bloom for u64 keys"*.

The fingerprint array is `u32[]` — 4 bytes per slot. At L4 with 2.5B slots, that's a 10 GB array. The proposal mlocks the L4 fingerprint+ctrl arrays for this reason. But **shallow layers (L1=40M=160 MB, L2=160M=640 MB) are also being probed newest-first on every miss**, and they are by definition not the hot working set — they're whatever isn't yet in L4. Probing each layer = 1 MPHF cache miss + 1 fingerprint cache miss. The proposal claims ~3 cache misses cold for the deepest layer but conveniently ignores that *every layer above also costs cache misses until the key is found*. Newest-first with ribbon prefilter only helps cold absence, not the warm-but-tail case.

Net: for keys living in L3 (640M), expected lookups touch L0 + L1 + L2 + L3 = 4 MPHF probes × 2 cache lines = 8 cache misses, not the "3 cache misses cold" the proposal advertises.

**Fix:** add a per-layer summary (e.g., a 2-bit "this slot range is populated" bitmap or per-layer Bloom) so shallow layers are skipped when the key is not present. The proposal already has xorf as a candidate — apply it to **all** frozen layers, not just L3+.

### M2. `bytemuck::cast_slice` on a partially-written mmap is UB even for `Pod` types
**Severity: likely bug.** `mmap_arena.rs:84-86, 90-94`.

`MmapArena::as_slice` returns `&[T]` covering `self.len * size_of::<T>()`. The proposal's Phase 4 publishes the layer **before the arena is flushed** (or worse, while it is still being appended to during compaction). If a reader's `as_slice` covers a region the writer thread is still memcpying into, you have a data race even when both sides only touch `Pod` types. Rust's UB rules say data races on shared memory are UB, period — `Pod` doesn't grant tear-free access.

There's also a more concrete bug: `as_slice` constructs a slice covering `self.len * size_of::<T>()` bytes. If a remote thread reads `self.len` while the writer is in the middle of `resize()` (which updates `self.len` only after `set_len` + `sync_all` + remap), the reader can see a stale-but-bigger `self.len` against a *new* `mmap` whose old VMA was just munmap'd by `MmapMut::map_mut`. → SIGBUS or read-from-unmapped-page.

**Fix:** all length and base-pointer fields must be loaded with `AtomicUsize`/`AtomicPtr` and stored after a release fence. Or: arenas must be append-only with a single-writer/many-reader contract where `len` is monotonic and never published until the corresponding page is written + msync'd.

### M3. `MADV_HUGEPAGE` + `mlock` interaction is platform-dependent and can OOM the host
**Severity: likely bug.** Section 2, "Cross-cutting infrastructure".

On Linux, `mlock` on a `MADV_HUGEPAGE` region forces the kernel to either (a) allocate 2 MiB pages (good) or (b) fall back to 4 KiB pages and pin them (bad — 10 GB locked × no swap → pathological under memory pressure). When the THP daemon (`khugepaged`) is in `madvise` mode and the system is fragmented, you frequently get (b). On a 256 GB box running near limits, this can OOM the host *because the kernel can't reclaim what it tried to give you*.

The proposal acknowledges *"mitigation is transparent_hugepage/defrag = madvise"* — but `defrag=madvise` is system-wide and requires sysctl access. On Hetzner / Hostkey shared boxes the user runs on, you don't always have it.

**Fix:** make hugepage advice optional and gated by a startup probe that checks `/sys/kernel/mm/transparent_hugepage/enabled` and `/proc/<pid>/smaps` to confirm pages were actually backed by 2 MiB after `mlock`. If the probe fails, fall back to no `MADV_HUGEPAGE` rather than silently shipping with 4 KiB pinned pages.

### M4. Batched prefetch across 8 lookups is meaningful only if all 8 keys are known up front
**Severity: cosmetic perf claim, but the "3-5× speedup" number is bogus.** Section 2 + Phase 5.

The MCCFR iter does 4 betting rounds × 2 players = 8 lookups. But **each lookup's key depends on the previous lookup's strategy distribution** (you sample an action, descend the tree, then look up the next info-set). You cannot prefetch lookup 5 before resolving lookup 4. The "8 lookups per iter" is sequential, not batched.

The only batching opportunity is **across iterations** (process 8 iters in parallel within a thread), which destroys the existing rayon thread model and complicates regret accumulation (now you're racing within a thread). Or, **within a single info-set across actions** (prefetch the n_actions × {regret,strategy} cache lines), which is trivially handled by the SwissTable group probe and doesn't deserve a "3-5×" claim.

**Fix:** rewrite Phase 5 with the actual prefetch opportunity (intra-info-set, ~10-30% gain) and drop the across-iter batching claim unless you redesign traversal.

## 3. Cosmetic / over-stated claims

### C1. "Zero reader blocking during freeze" — partially false
The freeze thread holds `&mut` to the hot map. The *owning* worker thread also wants `&mut` to that map (to insert new entries). The freeze cannot be wait-free for the owning thread. The proposal occasionally conflates "the 31 non-owning threads don't block" (true if you fix H1-H4) with "no thread blocks during freeze" (false — the owning thread either pauses or you need a second map per thread, doubling the steady-state cost).

### C2. PtrHash "2.4 bits/key" assumes uniform random keys
The proposal's open-question #1 flags this. Realistic: u64 hashes of (RBM bucket ID + board bucket ID + betting history) are not uniform until you confirm RBM bucket IDs are sampled uniformly across keys, which they aren't (preflop has 169 buckets, river has ~5000). PtrHash will still terminate, but the bits/key claim is an upper-bound advertisement, not a guarantee. **Re-budget at 3.5 bits/key (boomphf-comparable) and revisit only after a 100M-key construction trial.**

### C3. "OS page cache handles the wide tail via the kernel's 2-list LRU" is the proposal's hand-wave for the storage budget
At 10B keys × 15.4 B/key = 154 GB index + arenas. The proposal claims this hits <120 GB working-set budget because "only the hot subset is resident". This is true under uniform access but **MCCFR's access pattern has a heavy preflop skew** (preflop info-sets are visited every iter; river info-sets are visited rarely). The kernel's 2-list LRU will keep preflop hot and let everything else page in/out per iter. With 32 threads × 8 lookups × 4000 iter/sec = 1M lookups/sec and a working set substantially larger than RAM, page-fault rate dominates. The proposal does not estimate this. **Demand: fault-storm budget under 10B scale must be measured before Phase 5 ships.**

### C4. `arc-swap` claim of "wait-free reader" requires `Guard::load`, not `load_full`
This is implementation-detail-grade but worth flagging: `arc-swap` is wait-free for `load`, but `load_full` (which returns `Arc<T>`) does a refcount bump and is *lock-free* not wait-free. The proposal's prose ("wait-free multi-reader") sets a higher bar than the library delivers in the common usage. Fine if you know it; cosmetic otherwise.

## 4. Rust borrow-checker pain points that will block implementation

### B1. `Arc<LayerStack>` is fine; `Arc<FrozenCfrState>` is not
`FrozenCfrState` (current code) has `regret_arena: Vec<f32>` and `&mut self` methods. Wrapping it in `Arc` forces all writes through interior mutability. Either:
- Switch arenas to `UnsafeCell<[f32]>` with documented synchronization — but you've now opted out of the borrow checker for the hot path,
- Or split into `FrozenIndex` (read-only, in `Arc`) and `FrozenArenas` (per-shard mutable), and route mutations to the shard owner — substantial refactor, not in any phase.

The proposal silently assumes Option (b) without describing it. **Phase 4 will eat 1-2 weeks of refactoring not counted in its estimate.**

### B2. Per-layer `PhantomData<'a>` lifetimes across the `ArcSwap<LayerStack>` boundary
`LayerStack` containing `&'a [u32]` fingerprint slices owned by mmap'd files cannot be stored in `Arc` without lifetime parameters. Erasing to `'static` requires `Box::leak` (no reclamation) or self-referential structs (`ouroboros`, `yoke`, `rental`) — all of which the proposal's "vendor PtrHash, memmap2, arc-swap, crossbeam-epoch, bytemuck, rustc_hash" list omits.

**Fix:** add `yoke` or hand-rolled `Pin<Arc<MmapBackedLayer>>` with `unsafe impl Send + Sync` to the dependency list, or commit to a `'static`-leaked mmap and accept that memory grows monotonically with frozen-layer churn (compaction-only reclamation).

### B3. `rayon::ThreadPoolBuilder` + `set_mempolicy(MPOL_INTERLEAVE)` ordering is racy on rayon initialization
`set_mempolicy` affects the calling thread; rayon's worker threads inherit it **only if the policy is set before `spawn`**. The proposal says "at startup before rayon pool spawn" which is correct in principle, but rayon's *global* pool is lazily spawned on first use. Subtle: if any crate (including `arc-swap`'s tests, `ph::fmph`'s parallel build, or the existing parallel-RBM phase) touches rayon before your startup hook runs, the policy is missed on those workers permanently. The proposal does not describe a hard-failure check for this.

**Fix:** explicit `rayon::ThreadPoolBuilder::new()... .build()` with `start_handler` calling `set_mempolicy` per-worker. Drop reliance on inheritance.

## 5. Verdict

**Fix-and-ship — but `fix` is large.**

The high-level architecture (LSM-style frozen layers + hot overflow + arenas + atomic publish) is the right shape for the workload. The proposal is correct that off-the-shelf KV stores are overkill and that custom Rust + PtrHash is the right buy/build split. The phasing into independently shippable steps is sound.

But the **concurrency claims are aspirational and several are flat-out wrong**. Specifically:

| Hole | Severity | Minimum action |
|------|----------|----------------|
| H1: left-right + `arc-swap` + `FxHashMap` confusion | Showstopper | Pick one publishing primitive; per-thread L0 stays per-thread |
| H2: arena reclamation has no proof of safety | Showstopper | Bundle `Arc<ArenaSegment>` with every CompactEntry |
| H3: frozen layer is mutable, proposal claims immutable | Showstopper | Spec out side-tables / atomics for lazy DCFR, regret writes, strategy writes |
| H4: writer-thread blocks during freeze, contradicting design | Showstopper | Explicit dual-map per thread, account for 2× hot memory steady-state |
| H5: epoch-deferred munmap on lookup hot path | Showstopper | Dedicated reclamation thread; drop `MADV_DONTNEED` |
| M1: fingerprint claim only works at the deepest layer | Likely bug | Apply ribbon filter at every layer, not just L3+ |
| M2: `bytemuck::cast_slice` on resizing mmap is UB | Likely bug | Atomic len + base-pointer publication |
| M3: hugepages + mlock can OOM under fragmentation | Likely bug | Probe + fallback path |
| M4: cross-lookup prefetch impossible (dependent on prior result) | Cosmetic | Drop the 3-5× claim |
| B1: `Arc<FrozenCfrState>` does not compose with current `&mut` API | Borrow checker | Refactor into immutable index + mutable shards; add ~1 week to Phase 4 |
| B2: lifetimes across `ArcSwap` boundary need self-referential types | Borrow checker | Add `yoke` or commit to `Box::leak` |
| B3: `set_mempolicy` + rayon ordering is fragile | Cosmetic | Explicit rayon pool with `start_handler` |

**Specific minimum redesign before Phase 2 starts:**

1. Write down, in one document, exactly which data is owned by whom and under what synchronization (per-thread L0 map, shared frozen layer stack, per-generation arena segments). Each `&mut` and `&` in the API must be tagged with which thread holds it.
2. Decide and commit to **immutable frozen layers**. Move lazy DCFR, regret accumulation, and strategy accumulation entirely to the per-thread hot tier; they migrate into the next-built frozen layer at the next freeze, never written in place.
3. Replace `crossbeam-epoch`-deferred-munmap with `Arc<ArenaSegment>` bundled into every `CompactEntry`. The extra atomic per lookup is the price of soundness; ship it.
4. Build a 4-thread + synthetic-freeze stress test *before* Phase 2 lands, not after Phase 4. Test for: dropped writes during freeze, stale reads after publish, segfaults on arena reclamation, missing keys after compaction.
5. Drop the "wait-free", "zero blocking", "3-5× prefetch" marketing claims from the design doc. They're load-bearing in the proposal in a way that will paper over the real costs.

After those five, the LSM + PtrHash + mmap arena design is the right thing to build. The two weeks of redesign work pays back many weeks of post-deploy crashes at 1B+ scale.

**Files referenced:**
- `/home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/frozen_state.rs` (lines 152-262 — mutating "frozen" methods that break the immutability claim)
- `/home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/mmap_arena.rs` (lines 84-94, 120-142, 197-261 — resize / `as_slice` / open-existing path with the data-race window)
- `/home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/compact_state.rs` (lines 47-86 — pre-existing `FrozenLayer` / `FrozenIndex` skeleton that the proposal builds on but contradicts)
- `/home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/cfr_state.rs` (lines 53-108 — current per-thread state model the proposal silently changes)
- `/home/struktured/projects/recursive-bipartite-matching/rust/rbm_mccfr/src/train.rs` (lines 231-237, 403-448 — current single-threaded freeze trigger paths that the proposal replaces)