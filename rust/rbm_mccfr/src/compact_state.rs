/// Ultra-compact CFR state: split arena storage for regrets (i16) + strategy sums (f32).
///
/// Memory layout:
///   - FxHashMap<u64, CompactEntry> — metadata per info set
///   - Vec<i16> regret_arena  — contiguous storage for cumulative regrets
///   - Vec<f32> strategy_arena — contiguous storage for strategy sums
///
/// Each info set's data is laid out as:
///   regret_arena:   [regret_0, ..., regret_{n-1}]
///   strategy_arena: [strat_0, ..., strat_{n-1}]
///
/// i16 for regrets: CFR+ floors regrets to 0, and DCFR discounts keep them
/// bounded. ±32767 is more than enough.
///
/// f32 for strategy sums: with LCFR (iteration-weighted accumulation), strategy
/// sums reach millions at 25M iterations. i16 saturates at 32767, destroying the
/// averaged strategy. f32 handles values up to ~3.4e38 — no saturation.
///
/// Memory savings vs Vec<f32>:
///   - No per-entry heap allocation (24 bytes Vec overhead eliminated)
///   - Regrets: i16 = 2 bytes vs f32 = 4 bytes (2x compression)
///   - Strategy sums: f32 = 4 bytes (same as old)
///   - Compact index entry: ~12 bytes per entry
///   - Total: ~2x less memory for same number of info sets

use rustc_hash::FxHashMap;
use ph::fmph;
use crate::mmap_arena::MmapArena;

/// Compact index entry stored in the hash map.
/// Points into the split arenas where actual regret/strategy data lives.
#[derive(Clone, Copy, Debug)]
pub struct CompactEntry {
    /// Index into the regret_arena Vec<i16> where this entry's regrets start.
    /// u64: arenas can exceed u32::MAX (4.29B) entries at scale. Prior u32 caused
    /// silent offset wrap and corrupted ~26% of P1 strategies at iter 40M.
    pub regret_offset: u64,
    /// Index into the strategy_arena Vec<f32> where this entry's strategy sums start.
    pub strategy_offset: u64,
    /// Number of actions at this info set (max 12).
    pub n_actions: u8,
    /// Last DCFR discount epoch applied to this entry.
    /// An epoch is `iteration / 1000`. u16 covers 65535 epochs = 65.5M iters.
    pub last_discount_epoch: u16,
}

/// 32-bit fingerprint of a u64 info-set key. Used as a fast pre-filter
/// before the full key compare during frozen-layer lookups: on a fingerprint
/// miss we can skip touching the 8-byte keys array entirely.
///
/// MurmurHash3 finalizer — deterministic, branchless, ~3 cycles. The output
/// distribution is uniform even if the input keys are clustered, which
/// matters for the MPHF-derived slot ordering where lookups land at
/// "random" indices.
#[inline(always)]
pub fn fingerprint(key: u64) -> u32 {
    let mut x = key;
    x ^= x >> 33;
    x = x.wrapping_mul(0xff51_afd7_ed55_8ccd);
    x ^= x >> 33;
    x = x.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    x ^= x >> 33;
    x as u32
}

/// A single immutable MPHF layer with flat metadata arrays.
pub struct FrozenLayer {
    mphf: fmph::GOFunction,
    keys: Arena<u64>,
    n_actions: Arena<u8>,
    epochs: Arena<u16>,
    offsets: Arena<u64>,
    /// 32-bit fingerprint per slot — fast-path negative filter.
    /// `None` on layers loaded from disk that predate the fingerprint
    /// sidecar; lookups then skip the fast path and go straight to the
    /// full-key compare. Layers written by this build always populate it.
    fingerprints: Option<Arena<u32>>,
}

impl FrozenLayer {
    fn len(&self) -> usize {
        self.keys.len()
    }

    /// Look up a key in this layer. Returns slot index if found.
    ///
    /// Fast path: when the fingerprint sidecar is present, a 4-byte
    /// fingerprint compare rules out unknown keys before we touch the
    /// 8-byte keys array. False-positive rate is ~2^-32 per probe — the
    /// follow-up full-key compare catches the rare collision, so this is
    /// purely a perf optimization, not a correctness change.
    #[inline]
    fn lookup(&self, key: u64) -> Option<usize> {
        let slot = self.mphf.get(&key).unwrap_or(u64::MAX) as usize;
        if slot >= self.keys.len() {
            return None;
        }
        if let Some(ref fp) = self.fingerprints {
            if fp.get(slot) != fingerprint(key) {
                return None;
            }
        }
        if self.keys.get(slot) == key {
            Some(slot)
        } else {
            None
        }
    }
}

/// Layered frozen index — like an LSM tree of MPHFs.
///
/// Level 0 (base): large, rebuilt rarely (millions of entries)
/// Level 1+: smaller overflow layers, rebuilt frequently
/// FxHashMap: hot overflow (tiny, in RAM)
///
/// Lookup checks layers newest-first, then HashMap.
/// Incremental freeze: only builds MPHF for the overflow HashMap,
/// pushes it as a new layer. Full compaction merges all layers into
/// one (expensive, done rarely).
pub struct FrozenIndex {
    /// Frozen layers, ordered oldest (largest) to newest (smallest).
    layers: Vec<FrozenLayer>,
}

/// Arena backend: in-memory Vec or disk-backed mmap.
pub enum Arena<T: Copy + Default + bytemuck::Pod> {
    Mem(Vec<T>),
    Mmap(MmapArena<T>),
}

impl<T: Copy + Default + bytemuck::Pod> Arena<T> {
    #[inline(always)]
    pub fn len(&self) -> usize {
        match self { Arena::Mem(v) => v.len(), Arena::Mmap(m) => m.len() }
    }

    #[inline(always)]
    pub fn get(&self, idx: usize) -> T {
        match self {
            Arena::Mem(v) => v[idx],
            Arena::Mmap(m) => m.get(idx),
        }
    }

    #[inline(always)]
    pub fn set(&mut self, idx: usize, val: T) {
        match self {
            Arena::Mem(v) => v[idx] = val,
            Arena::Mmap(m) => m.set(idx, val),
        }
    }

    pub fn resize(&mut self, new_len: usize, fill: T) {
        match self {
            Arena::Mem(v) => v.resize(new_len, fill),
            Arena::Mmap(m) => m.resize(new_len, fill).expect("mmap resize failed"),
        }
    }

    pub fn iter_mut(&mut self) -> Box<dyn Iterator<Item = &mut T> + '_> {
        match self {
            Arena::Mem(v) => Box::new(v.iter_mut()),
            Arena::Mmap(m) => Box::new(m.iter_mut()),
        }
    }

    /// Clone (only for Mem variant — mmap arenas can't be cloned).
    pub fn clone_mem(&self) -> Self {
        match self {
            Arena::Mem(v) => Arena::Mem(v.clone()),
            Arena::Mmap(_) => panic!("cannot clone mmap arena"),
        }
    }

    /// Push an element (only for Mem variant).
    pub fn push(&mut self, val: T) {
        match self {
            Arena::Mem(v) => v.push(val),
            Arena::Mmap(_) => {
                // For mmap: grow and set
                let idx = self.len();
                self.resize(idx + 1, val);
                self.set(idx, val);
            }
        }
    }

    /// Iterate (read-only).
    pub fn iter(&self) -> Box<dyn Iterator<Item = &T> + '_> {
        match self {
            Arena::Mem(v) => Box::new(v.iter()),
            Arena::Mmap(m) => {
                let slice = bytemuck::cast_slice::<u8, T>(m.as_ref());
                Box::new(slice.iter())
            }
        }
    }

    /// Direct Vec access for checkpoint save/load (panics on mmap).
    pub fn as_vec(&self) -> &Vec<T> {
        match self {
            Arena::Mem(v) => v,
            Arena::Mmap(_) => panic!("as_vec on mmap arena — use checkpoint with in-memory state"),
        }
    }

    pub fn as_vec_mut(&mut self) -> &mut Vec<T> {
        match self {
            Arena::Mem(v) => v,
            Arena::Mmap(_) => panic!("as_vec_mut on mmap arena"),
        }
    }

    /// Create from a Vec (wraps in Mem variant).
    pub fn from_vec(v: Vec<T>) -> Self {
        Arena::Mem(v)
    }

    /// Create empty with capacity.
    pub fn with_capacity(cap: usize) -> Self {
        Arena::Mem(Vec::with_capacity(cap))
    }
}

impl<T: Copy + Default + bytemuck::Pod> std::ops::Index<usize> for Arena<T> {
    type Output = T;
    #[inline(always)]
    fn index(&self, idx: usize) -> &T {
        match self {
            Arena::Mem(v) => &v[idx],
            Arena::Mmap(m) => {
                let bytes = &m.as_ref()[idx * std::mem::size_of::<T>()..(idx + 1) * std::mem::size_of::<T>()];
                &bytemuck::cast_slice::<u8, T>(bytes)[0]
            }
        }
    }
}

impl<T: Copy + Default + bytemuck::Pod> std::ops::IndexMut<usize> for Arena<T> {
    #[inline(always)]
    fn index_mut(&mut self, idx: usize) -> &mut T {
        match self {
            Arena::Mem(v) => &mut v[idx],
            Arena::Mmap(m) => {
                let sz = std::mem::size_of::<T>();
                let bytes = &mut m.as_mut()[idx * sz..(idx + 1) * sz];
                &mut bytemuck::cast_slice_mut::<u8, T>(bytes)[0]
            }
        }
    }
}

/// Per-player compact CFR state with split storage:
/// - i16 arena for regrets (bounded by CFR+ flooring + DCFR discount)
/// - f32 arena for strategy sums (grow unboundedly with LCFR weighting)
pub struct CompactCfrState {
    /// Index: info key -> compact entry metadata
    pub index: FxHashMap<u64, CompactEntry>,
    /// Regret arena: contiguous f32 storage.
    /// Was i16 + saturation-clamping + halve_regrets cycle; switched to f32
    /// to eliminate the precision loss from the halve cycle (Rust pipeline
    /// regression vs OCaml f32 baseline).
    pub regret_arena: Arena<f32>,
    /// Strategy arena: contiguous f32 storage.
    pub strategy_arena: Arena<f32>,
    /// Optional frozen MPHF index. When set, find_or_add checks MPHF first.
    pub(crate) frozen: Option<FrozenIndex>,
    /// Player ID for mmap file naming.
    pub(crate) player_id: u8,
    pub(crate) use_mmap: bool,
    /// Directory for mmap files (regret/strategy/frozen layers). Set by new_mmap.
    /// In parallel training, each thread gets its own subdir to avoid path
    /// collisions when multiple threads call freeze() concurrently.
    pub(crate) mmap_dir: std::path::PathBuf,
    /// Phase 3 freeze-time pruning: drop entries from the new frozen layer
    /// when every action's `|regret| < freeze_prune_regret` AND
    /// `sum(|strategy|) < freeze_prune_strategy`. Both default to 0.0 (no
    /// pruning). The arena slots of pruned entries become unreferenced
    /// "garbage" — they stay allocated for now and get reclaimed by Phase 5's
    /// per-generation arena compaction.
    pub(crate) freeze_prune_regret: f32,
    pub(crate) freeze_prune_strategy: f32,
}

impl CompactCfrState {
    pub fn new(capacity: usize) -> Self {
        let regret_capacity = capacity * 6;
        let strategy_capacity = capacity * 6;
        Self {
            index: FxHashMap::with_capacity_and_hasher(capacity, Default::default()),
            regret_arena: Arena::Mem(Vec::with_capacity(regret_capacity)),
            strategy_arena: Arena::Mem(Vec::with_capacity(strategy_capacity)),
            frozen: None,
            player_id: 0,
            use_mmap: false,
            mmap_dir: std::path::PathBuf::from("."),
            freeze_prune_regret: 0.0,
            freeze_prune_strategy: 0.0,
        }
    }

    /// Enable Phase 3 freeze-time pruning. Both thresholds must be > 0 for
    /// pruning to fire. An entry is dropped from the new frozen layer when
    /// every action's `|regret| < regret_threshold` AND
    /// `sum(|strategy|) < strategy_threshold`. Default state (no setter
    /// called) is 0.0/0.0 → no pruning, no behavior change.
    pub fn set_freeze_prune_thresholds(&mut self, regret: f32, strategy: f32) {
        self.freeze_prune_regret = regret;
        self.freeze_prune_strategy = strategy;
    }

    /// Returns true if the given entry passes the prune predicate (i.e.
    /// should be DROPPED from the new frozen layer). Returns false when
    /// pruning is disabled (both thresholds == 0).
    #[inline]
    fn should_prune(&self, entry: &CompactEntry) -> bool {
        // Pruning is opt-in: both thresholds must be positive.
        if self.freeze_prune_regret <= 0.0 || self.freeze_prune_strategy <= 0.0 {
            return false;
        }
        let n = entry.n_actions as usize;
        let r_base = entry.regret_offset as usize;
        let s_base = entry.strategy_offset as usize;

        // Every action's |regret| must be small.
        let mut max_abs_regret = 0.0f32;
        for i in 0..n {
            let r = self.regret_arena.get(r_base + i).abs();
            if r > max_abs_regret { max_abs_regret = r; }
        }
        if max_abs_regret >= self.freeze_prune_regret {
            return false;
        }

        // Sum of absolute strategy contributions must also be small.
        let mut sum_abs_strategy = 0.0f32;
        for i in 0..n {
            sum_abs_strategy += self.strategy_arena.get(s_base + i).abs();
        }
        sum_abs_strategy < self.freeze_prune_strategy
    }

    /// Load a CompactCfrState for a given player by reading the training directory's
    /// on-disk state: `regret_p{player}.bin`, `strategy_p{player}.bin`, and all
    /// `frozen_keys_p{player}_L{layer}.bin` / `frozen_na/ep/off_p{player}_L{layer}.bin`
    /// sidecar files.
    ///
    /// This is the evaluator-side recovery for the RBMCMP02 checkpoint format, which
    /// silently omits all frozen MPHF layer data (see `save_compact_raw_states`).
    /// The trained strategy lives on disk in these sidecar files; this function
    /// reconstructs the in-memory `CompactCfrState` such that queries resolve against
    /// the same data that training was using.
    ///
    /// The in-memory `index` HashMap is left empty — any unfrozen overflow from the
    /// last training cycle is inaccessible, but in a converged run the vast majority
    /// of info sets have been pushed into frozen layers and the overflow is <1% of
    /// the total. For eval this is a tolerable loss.
    pub fn load_from_dir(dir: &std::path::Path, player: u8) -> std::io::Result<Self> {
        let regret_path = dir.join(format!("regret_p{}.bin", player));
        let strategy_path = dir.join(format!("strategy_p{}.bin", player));

        let regret_arena = Arena::Mmap(MmapArena::<f32>::open_existing(&regret_path)?);
        let strategy_arena = Arena::Mmap(MmapArena::<f32>::open_existing(&strategy_path)?);

        // Walk frozen layers L0, L1, ... contiguously. Pre-fix this loop
        // silently `break`d on the first missing keys file, which masked two
        // distinct hazards: (a) a partially-written training run where L0
        // was missing but L1+ existed (gap → silently truncated index → 99%
        // uniform-random play), and (b) any one of the four sidecar files
        // (keys/na/ep/off) being truncated mid-write while the others were
        // intact (length mismatch → garbage reads via MPHF slot lookup).
        // We now require all four sidecars per layer to exist together with
        // matching lengths, and we error out on a layer-id gap rather than
        // silently stopping enumeration short.
        let mut layers: Vec<FrozenLayer> = Vec::new();
        for layer_id in 0usize.. {
            let keys_path = dir.join(format!("frozen_keys_p{}_L{}.bin", player, layer_id));
            let na_path = dir.join(format!("frozen_na_p{}_L{}.bin", player, layer_id));
            let ep_path = dir.join(format!("frozen_ep_p{}_L{}.bin", player, layer_id));
            let off_path = dir.join(format!("frozen_off_p{}_L{}.bin", player, layer_id));

            let any_present = keys_path.exists() || na_path.exists()
                || ep_path.exists() || off_path.exists();
            let all_present = keys_path.exists() && na_path.exists()
                && ep_path.exists() && off_path.exists();

            if !any_present {
                // End of the contiguous layer chain — normal termination.
                break;
            }
            if !all_present {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!(
                        "p{} layer {}: partial sidecar set in {:?} \
                         (keys={} na={} ep={} off={}) — refusing to load \
                         a torn frozen layer. Investigate before resuming.",
                        player, layer_id, dir,
                        keys_path.exists(), na_path.exists(),
                        ep_path.exists(), off_path.exists(),
                    ),
                ));
            }

            let keys_mmap = MmapArena::<u64>::open_existing(&keys_path)?;
            let na_mmap = MmapArena::<u8>::open_existing(&na_path)?;
            let ep_mmap = MmapArena::<u16>::open_existing(&ep_path)?;
            let off_mmap = MmapArena::<u64>::open_existing(&off_path)?;

            let n = keys_mmap.len();
            // All four sidecars must have identical length. Pre-fix, a
            // truncated na/ep/off would silently misalign with keys and
            // every MPHF slot lookup past the truncation point would read
            // zero bytes — i.e. n_actions=0 frozen entries that the
            // traversal layer would later interpret as "this info set has
            // no actions" and produce nonsense regret accumulations.
            if na_mmap.len() != n || ep_mmap.len() != n || off_mmap.len() != n {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!(
                        "p{} layer {}: sidecar length mismatch in {:?} \
                         (keys={} na={} ep={} off={})",
                        player, layer_id, dir,
                        n, na_mmap.len(), ep_mmap.len(), off_mmap.len(),
                    ),
                ));
            }

            // Fingerprint sidecar is optional (introduced 2026-06-03).
            // Runs predating this build have no fp file; we accept them
            // and let lookups fall through to the full-key check.
            // New runs always emit fp, so the missing-fp branch only fires
            // on legacy on-disk state.
            let fp_path = dir.join(format!("frozen_fp_p{}_L{}.bin", player, layer_id));
            let fp_mmap = if fp_path.exists() {
                let m = MmapArena::<u32>::open_existing(&fp_path)?;
                if m.len() != n {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!(
                            "p{} layer {}: fingerprint sidecar length {} \
                             differs from keys length {} in {:?} — torn write?",
                            player, layer_id, m.len(), n, dir,
                        ),
                    ));
                }
                Some(Arena::Mmap(m))
            } else {
                None
            };

            // MPHF is not persisted — rebuild from keys. For small layers (15-30M keys)
            // this is ~2-3 seconds; for compacted layers (1B+ keys) it can be minutes.
            let mut keys_vec: Vec<u64> = Vec::with_capacity(n);
            for i in 0..n {
                keys_vec.push(keys_mmap.get(i));
            }
            eprintln!("[load_from_dir] rebuilding MPHF for p{} layer {} ({} keys, fp={})...",
                player, layer_id, n, if fp_mmap.is_some() { "yes" } else { "no" });
            let start = std::time::Instant::now();
            let mphf = fmph::GOFunction::from_slice(&keys_vec);
            eprintln!("[load_from_dir] p{} layer {} MPHF built in {:.1}s",
                player, layer_id, start.elapsed().as_secs_f64());

            layers.push(FrozenLayer {
                mphf,
                keys: Arena::Mmap(keys_mmap),
                n_actions: Arena::Mmap(na_mmap),
                epochs: Arena::Mmap(ep_mmap),
                offsets: Arena::Mmap(off_mmap),
                fingerprints: fp_mmap,
            });
        }

        let frozen = if layers.is_empty() {
            None
        } else {
            Some(FrozenIndex { layers })
        };

        Ok(Self {
            index: FxHashMap::with_capacity_and_hasher(1024, Default::default()),
            regret_arena,
            strategy_arena,
            frozen,
            player_id: player,
            use_mmap: true,
            mmap_dir: dir.to_path_buf(),
            freeze_prune_regret: 0.0,
            freeze_prune_strategy: 0.0,
        })
    }

    /// Create a new state with mmap-backed arenas for low-memory training.
    pub fn new_mmap(capacity: usize, dir: &std::path::Path, player: u8) -> Self {
        let regret_path = dir.join(format!("regret_p{}.bin", player));
        let strategy_path = dir.join(format!("strategy_p{}.bin", player));
        let regret_cap = capacity * 6;
        let strategy_cap = capacity * 6;
        Self {
            index: FxHashMap::with_capacity_and_hasher(capacity, Default::default()),
            regret_arena: Arena::Mmap(MmapArena::new(&regret_path, regret_cap)
                .expect("failed to create regret mmap")),
            strategy_arena: Arena::Mmap(MmapArena::new(&strategy_path, strategy_cap)
                .expect("failed to create strategy mmap")),
            frozen: None,
            player_id: player,
            use_mmap: true,
            mmap_dir: dir.to_path_buf(),
            freeze_prune_regret: 0.0,
            freeze_prune_strategy: 0.0,
        }
    }

    pub fn len(&self) -> usize {
        let frozen_len = self.frozen.as_ref()
            .map_or(0, |f| f.layers.iter().map(|l| l.len()).sum());
        self.index.len() + frozen_len
    }

    /// Is this state frozen (using MPHF index)?
    pub fn is_frozen(&self) -> bool {
        self.frozen.is_some()
    }

    /// Incremental freeze: build MPHF from overflow HashMap only,
    /// push as a new layer. Existing layers are untouched.
    ///
    /// Like an LSM tree: each freeze creates a small new layer.
    /// Lookup checks layers newest-first. O(layers) per lookup,
    /// but layers are small and few (typically 10-30).
    ///
    /// This avoids the 15-minute full rebuild at 3B+ entries.
    pub fn freeze(&mut self) {
        let overflow_len = self.index.len();
        if overflow_len == 0 {
            return;
        }

        let n_layers = self.frozen.as_ref().map_or(0, |f| f.layers.len());
        let total_frozen: usize = self.frozen.as_ref()
            .map_or(0, |f| f.layers.iter().map(|l| l.len()).sum());

        // Phase 3: build the set of keys that survive freeze-time pruning.
        // When `freeze_prune_regret > 0 && freeze_prune_strategy > 0`, drop
        // entries whose every action's |regret| is below the regret
        // threshold AND whose absolute strategy-sum is below the strategy
        // threshold. The arena slots of dropped entries become unreferenced
        // "garbage" until Phase 5's per-generation arena compaction; this
        // is intentional — we never reuse arena slots in place, so the
        // surviving entries' offsets remain stable.
        let prune_enabled = self.freeze_prune_regret > 0.0
            && self.freeze_prune_strategy > 0.0;
        let mut surviving_keys: Vec<u64> = Vec::with_capacity(overflow_len);
        if prune_enabled {
            for (&key, entry) in &self.index {
                if !self.should_prune(entry) {
                    surviving_keys.push(key);
                }
            }
        } else {
            surviving_keys.extend(self.index.keys().copied());
        }
        let n = surviving_keys.len();
        let pruned_count = overflow_len - n;

        if prune_enabled {
            eprintln!(
                "[freeze] Pruned {} / {} overflow entries ({:.1}%); building MPHF for {} survivors ({} existing layers, {} frozen total)...",
                pruned_count,
                overflow_len,
                100.0 * pruned_count as f64 / overflow_len as f64,
                n,
                n_layers,
                total_frozen,
            );
        } else {
            eprintln!(
                "[freeze] Building MPHF for {} overflow entries ({} existing layers, {} frozen total)...",
                overflow_len, n_layers, total_frozen
            );
        }
        let start = std::time::Instant::now();

        // Edge case: every entry was pruned. There is nothing to freeze;
        // clear the overflow and bail. Returning before constructing an
        // empty MPHF avoids a zero-key MPHF build (which fmph rejects).
        if n == 0 {
            self.index.clear();
            self.index.shrink_to(1024);
            return;
        }

        // Build MPHF from surviving keys only
        let mphf = fmph::GOFunction::from_slice(&surviving_keys);

        // Build flat arrays for this layer
        let mut keys = vec![0u64; n];
        let mut n_actions_arr = vec![0u8; n];
        let mut epochs_arr = vec![0u16; n];
        let mut offsets_arr = vec![0u64; n];
        let mut fingerprints_arr = vec![0u32; n];

        for key in &surviving_keys {
            let entry = self.index[key];
            let slot = mphf.get(key).unwrap_or(u64::MAX) as usize;
            keys[slot] = *key;
            n_actions_arr[slot] = entry.n_actions;
            epochs_arr[slot] = entry.last_discount_epoch;
            offsets_arr[slot] = entry.regret_offset;
            fingerprints_arr[slot] = fingerprint(*key);
        }

        let old_overflow_bytes = overflow_len * 48;
        self.index.clear();
        self.index.shrink_to(1024);

        // +4 bytes per entry for the fingerprint sidecar.
        let new_layer_bytes = n * 19;

        // Convert to mmap if enabled
        fn vec_to_mmap<T: Copy + Default + bytemuck::Pod>(
            v: Vec<T>, path: &std::path::Path,
        ) -> Arena<T> {
            let n = v.len();
            let mut m = MmapArena::new(path, n).expect("mmap create failed");
            m.resize(n, T::default()).expect("mmap resize failed");
            for (i, &val) in v.iter().enumerate() {
                m.set(i, val);
            }
            Arena::Mmap(m)
        }

        let layer_id = n_layers;
        let (k, na, ep, off, fp) = if self.use_mmap {
            let dir = self.mmap_dir.as_path();
            let p = self.player_id;
            (
                vec_to_mmap(keys, &dir.join(format!("frozen_keys_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(n_actions_arr, &dir.join(format!("frozen_na_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(epochs_arr, &dir.join(format!("frozen_ep_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(offsets_arr, &dir.join(format!("frozen_off_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(fingerprints_arr, &dir.join(format!("frozen_fp_p{}_L{}.bin", p, layer_id))),
            )
        } else {
            (
                Arena::Mem(keys),
                Arena::Mem(n_actions_arr),
                Arena::Mem(epochs_arr),
                Arena::Mem(offsets_arr),
                Arena::Mem(fingerprints_arr),
            )
        };

        let new_layer = FrozenLayer {
            mphf,
            keys: k,
            n_actions: na,
            epochs: ep,
            offsets: off,
            fingerprints: Some(fp),
        };

        // Push new layer
        match &mut self.frozen {
            Some(f) => f.layers.push(new_layer),
            None => self.frozen = Some(FrozenIndex { layers: vec![new_layer] }),
        }

        let total_layers = self.frozen.as_ref().map_or(0, |f| f.layers.len());
        eprintln!(
            "[freeze] Complete in {:.1}s: layer {} with {} entries ({} layers total). Overflow {}MB freed, layer = {}MB",
            start.elapsed().as_secs_f64(),
            layer_id,
            n,
            total_layers,
            old_overflow_bytes / 1024 / 1024,
            new_layer_bytes / 1024 / 1024,
        );

        // Compact layers if too many (prevents O(layers) lookup slowdown).
        // Merges all layers into one by rebuilding MPHF from combined keys.
        const MAX_LAYERS: usize = 20;
        if total_layers > MAX_LAYERS {
            self.compact_layers();
        }
    }

    /// Merge all frozen layers into a single layer.
    /// Rebuilds MPHF from combined keys. Arena offsets stay valid.
    fn compact_layers(&mut self) {
        let frozen = match self.frozen.take() {
            Some(f) => f,
            None => return,
        };

        let total: usize = frozen.layers.iter().map(|l| l.len()).sum();
        eprintln!("[compact] Merging {} layers ({} entries) into 1...", frozen.layers.len(), total);
        let start = std::time::Instant::now();

        // Collect all keys
        let mut all_keys: Vec<u64> = Vec::with_capacity(total);
        for layer in &frozen.layers {
            for i in 0..layer.len() {
                all_keys.push(layer.keys.get(i));
            }
        }

        let mphf = fmph::GOFunction::from_slice(&all_keys);

        // Build merged flat arrays
        let mut keys = vec![0u64; total];
        let mut n_actions_arr = vec![0u8; total];
        let mut epochs_arr = vec![0u16; total];
        let mut offsets_arr = vec![0u64; total];
        let mut fingerprints_arr = vec![0u32; total];

        for layer in &frozen.layers {
            for i in 0..layer.len() {
                let key = layer.keys.get(i);
                let slot = mphf.get(&key).unwrap_or(u64::MAX) as usize;
                keys[slot] = key;
                n_actions_arr[slot] = layer.n_actions.get(i);
                epochs_arr[slot] = layer.epochs.get(i);
                offsets_arr[slot] = layer.offsets.get(i);
                fingerprints_arr[slot] = fingerprint(key);
            }
        }

        drop(frozen); // Free old layers

        // Convert to mmap if needed
        let layer_id = 0;
        let (k, na, ep, off, fp) = if self.use_mmap {
            let dir = self.mmap_dir.as_path();
            let p = self.player_id;

            fn vec_to_mmap<T: Copy + Default + bytemuck::Pod>(
                v: Vec<T>, path: &std::path::Path,
            ) -> Arena<T> {
                let n = v.len();
                let mut m = crate::mmap_arena::MmapArena::new(path, n).expect("mmap create failed");
                m.resize(n, T::default()).expect("mmap resize failed");
                for (i, &val) in v.iter().enumerate() {
                    m.set(i, val);
                }
                Arena::Mmap(m)
            }

            (
                vec_to_mmap(keys, &dir.join(format!("frozen_keys_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(n_actions_arr, &dir.join(format!("frozen_na_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(epochs_arr, &dir.join(format!("frozen_ep_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(offsets_arr, &dir.join(format!("frozen_off_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(fingerprints_arr, &dir.join(format!("frozen_fp_p{}_L{}.bin", p, layer_id))),
            )
        } else {
            (
                Arena::Mem(keys),
                Arena::Mem(n_actions_arr),
                Arena::Mem(epochs_arr),
                Arena::Mem(offsets_arr),
                Arena::Mem(fingerprints_arr),
            )
        };

        self.frozen = Some(FrozenIndex {
            layers: vec![FrozenLayer {
                mphf,
                keys: k,
                n_actions: na,
                epochs: ep,
                offsets: off,
                fingerprints: Some(fp),
            }],
        });

        eprintln!("[compact] Complete in {:.1}s: {} entries in 1 layer", start.elapsed().as_secs_f64(), total);
    }

    /// Get the regret value for action `i` at the given entry.
    #[inline(always)]
    pub fn regret(&self, entry: &CompactEntry, i: usize) -> f32 {
        self.regret_arena.get(entry.regret_offset as usize + i)
    }

    /// Get the strategy sum for action `i` at the given entry.
    #[inline(always)]
    pub fn strategy(&self, entry: &CompactEntry, i: usize) -> f32 {
        self.strategy_arena.get(entry.strategy_offset as usize + i)
    }

    /// Add a delta to regret for action `i`. f32 storage — no clamping.
    #[inline(always)]
    pub fn add_regret(&mut self, entry: &CompactEntry, i: usize, delta: f32) {
        let idx = entry.regret_offset as usize + i;
        let new = self.regret_arena.get(idx) + delta;
        self.regret_arena.set(idx, new);
    }

    /// Set regret for action `i`. f32 storage — no clamping.
    #[inline(always)]
    pub fn set_regret(&mut self, entry: &CompactEntry, i: usize, v: f32) {
        let idx = entry.regret_offset as usize + i;
        self.regret_arena.set(idx, v);
    }

    /// Add a delta to strategy sum for action `i`. Direct f32 add — no clamping.
    #[inline(always)]
    pub fn add_strategy(&mut self, entry: &CompactEntry, i: usize, delta: f32) {
        let idx = entry.strategy_offset as usize + i;
        let old = self.strategy_arena.get(idx);
        self.strategy_arena.set(idx, old + delta);
    }

    /// Set strategy sum for action `i`. Direct f32 — no clamping.
    #[inline(always)]
    pub fn set_strategy(&mut self, entry: &CompactEntry, i: usize, v: f32) {
        self.strategy_arena.set(entry.strategy_offset as usize + i, v);
    }

    /// Halve all regrets in the arena. With f32 storage this is rarely
    /// needed (no saturation) but kept for backward-compat with DCFR-style
    /// periodic discounting.
    pub fn halve_regrets(&mut self) {
        for r in self.regret_arena.iter_mut() {
            *r *= 0.5;
        }
    }

    /// Get or create an entry for the given key. Returns a copy of the entry.
    /// Checks frozen layers (newest first), then HashMap overflow.
    #[inline]
    pub fn find_or_add(&mut self, key: u64, n_actions: u8) -> CompactEntry {
        // Check frozen layers (newest first for temporal locality)
        if let Some(ref frozen) = self.frozen {
            for layer in frozen.layers.iter().rev() {
                if let Some(slot) = layer.lookup(key) {
                    return CompactEntry {
                        regret_offset: layer.offsets.get(slot),
                        strategy_offset: layer.offsets.get(slot),
                        n_actions: layer.n_actions.get(slot),
                        last_discount_epoch: layer.epochs.get(slot),
                    };
                }
            }
        }
        // HashMap path (normal or overflow)
        if let Some(&entry) = self.index.get(&key) {
            return entry;
        }
        let regret_offset = self.regret_arena.len() as u64;
        let strategy_offset = self.strategy_arena.len() as u64;
        let n = n_actions as usize;
        self.regret_arena.resize(self.regret_arena.len() + n, 0.0f32);
        self.strategy_arena.resize(self.strategy_arena.len() + n, 0.0f32);
        let entry = CompactEntry {
            regret_offset,
            strategy_offset,
            n_actions,
            last_discount_epoch: 0,
        };
        self.index.insert(key, entry);
        entry
    }

    /// Get or create an entry, applying lazy DCFR discount if the entry is stale.
    /// If frozen, checks MPHF first (fast path) with discount applied to flat arrays.
    #[inline]
    pub fn find_or_add_lazy_dcfr(
        &mut self,
        key: u64,
        n_actions: u8,
        current_epoch: u16,
        dcfr_table: &super::cfr_state::DcfrTable,
    ) -> CompactEntry {
        // Check frozen layers (newest first)
        if let Some(ref mut frozen) = self.frozen {
            for layer in frozen.layers.iter_mut().rev() {
                if let Some(slot) = layer.lookup(key) {
                    if layer.epochs.get(slot) < current_epoch {
                        let (pos_factor, neg_factor, strat_factor) =
                            dcfr_table.discount_factors(layer.epochs.get(slot) as u32, current_epoch as u32);
                        let n = layer.n_actions.get(slot) as usize;
                        let base = layer.offsets.get(slot) as usize;
                        for i in 0..n {
                            let r = self.regret_arena.get(base + i);
                            let w = if r >= 0.0 { pos_factor } else { neg_factor };
                            self.regret_arena.set(base + i, r * w as f32);
                        }
                        for i in 0..n {
                            let old = self.strategy_arena.get(base + i);
                            self.strategy_arena.set(base + i, old * strat_factor as f32);
                        }
                        layer.epochs.set(slot, current_epoch);
                    }
                    return CompactEntry {
                        regret_offset: layer.offsets.get(slot),
                        strategy_offset: layer.offsets.get(slot),
                        n_actions: layer.n_actions.get(slot),
                        last_discount_epoch: layer.epochs.get(slot),
                    };
                }
            }
        }

        // HashMap path (normal or overflow)
        if let Some(entry) = self.index.get_mut(&key) {
            if entry.last_discount_epoch < current_epoch {
                let (pos_factor, neg_factor, strat_factor) =
                    dcfr_table.discount_factors(entry.last_discount_epoch as u32, current_epoch as u32);
                let n = entry.n_actions as usize;
                let r_base = entry.regret_offset as usize;
                let s_base = entry.strategy_offset as usize;
                for i in 0..n {
                    let r = self.regret_arena[r_base + i];
                    let w = if r >= 0.0 { pos_factor } else { neg_factor };
                    self.regret_arena[r_base + i] = r * w as f32;
                }
                for i in 0..n {
                    self.strategy_arena[s_base + i] *= strat_factor as f32;
                }
                entry.last_discount_epoch = current_epoch;
            }
            return *entry;
        }

        // New entry (into HashMap)
        let regret_offset = self.regret_arena.len() as u64;
        let strategy_offset = self.strategy_arena.len() as u64;
        let n = n_actions as usize;
        self.regret_arena.resize(self.regret_arena.len() + n, 0.0f32);
        self.strategy_arena.resize(self.strategy_arena.len() + n, 0.0f32);
        let entry = CompactEntry {
            regret_offset,
            strategy_offset,
            n_actions,
            last_discount_epoch: current_epoch,
        };
        self.index.insert(key, entry);
        entry
    }

    /// Update the last_discount_epoch for an entry in the index.
    #[inline(always)]
    pub fn update_epoch(&mut self, key: u64, epoch: u16) {
        if let Some(entry) = self.index.get_mut(&key) {
            entry.last_discount_epoch = epoch;
        }
    }
}

// -----------------------------------------------------------------------
// Free functions matching the cfr_state API
// -----------------------------------------------------------------------

/// Regret matching: convert cumulative regrets into a strategy.
/// Output written to `out` slice (avoids allocation).
#[inline]
pub fn regret_matching(state: &CompactCfrState, entry: &CompactEntry, out: &mut [f32]) {
    let n = entry.n_actions as usize;
    let base = entry.regret_offset as usize;
    let mut pos_sum: f32 = 0.0;
    for i in 0..n {
        let r = (state.regret_arena[base + i] as f32).max(0.0);
        out[i] = r;
        pos_sum += r;
    }
    if pos_sum > 0.0 {
        let inv = 1.0 / pos_sum;
        for i in 0..n {
            out[i] *= inv;
        }
    } else {
        let uniform = 1.0 / n as f32;
        for i in 0..n {
            out[i] = uniform;
        }
    }
}

/// Regret matching with pruning: actions below threshold get probability 0.
#[inline]
pub fn regret_matching_pruned(
    state: &CompactCfrState,
    entry: &CompactEntry,
    threshold: f32,
    strat_out: &mut [f32],
    pruned_out: &mut [bool],
) {
    let n = entry.n_actions as usize;
    let base = entry.regret_offset as usize;
    let mut pos_sum: f32 = 0.0;
    for i in 0..n {
        let r = state.regret_arena[base + i] as f32;
        if r < threshold {
            strat_out[i] = 0.0;
            pruned_out[i] = true;
        } else {
            let rp = r.max(0.0);
            strat_out[i] = rp;
            pos_sum += rp;
            pruned_out[i] = false;
        }
    }
    if pos_sum > 0.0 {
        let inv = 1.0 / pos_sum;
        for i in 0..n {
            if !pruned_out[i] {
                strat_out[i] *= inv;
            }
        }
    } else {
        let mut count = 0u8;
        for i in 0..n {
            if !pruned_out[i] {
                count += 1;
            }
        }
        if count > 0 {
            let uniform = 1.0 / count as f32;
            for i in 0..n {
                strat_out[i] = if pruned_out[i] { 0.0 } else { uniform };
            }
        } else {
            let uniform = 1.0 / n as f32;
            for i in 0..n {
                strat_out[i] = uniform;
                pruned_out[i] = false;
            }
        }
    }
}

/// Accumulate strategy contribution (with optional LCFR weighting).
#[inline]
pub fn accumulate_strategy(
    state: &mut CompactCfrState,
    entry: &CompactEntry,
    strat: &[f32],
    weight: f32,
    lcfr_iter: u32,
) {
    let n = entry.n_actions as usize;
    let base = entry.strategy_offset as usize;
    let iter_weight = if lcfr_iter > 0 {
        weight * lcfr_iter as f32
    } else {
        weight
    };
    for i in 0..n {
        state.strategy_arena[base + i] += iter_weight * strat[i];
    }
}

/// DCFR discount: scale regrets and strategy sums (bulk, non-lazy).
pub fn apply_dcfr_discount(
    state: &mut CompactCfrState,
    pos_weight: f32,
    neg_weight: f32,
    strat_weight: f32,
) {
    for entry in state.index.values() {
        let n = entry.n_actions as usize;
        let r_base = entry.regret_offset as usize;
        let s_base = entry.strategy_offset as usize;
        // Discount regrets (f32)
        for i in 0..n {
            let r = state.regret_arena[r_base + i];
            let w = if r >= 0.0 { pos_weight } else { neg_weight };
            state.regret_arena[r_base + i] = r * w;
        }
        // Discount strategy sums (f32)
        for i in 0..n {
            state.strategy_arena[s_base + i] *= strat_weight;
        }
    }
}

/// Average strategy: normalize strategy sums.
/// Iterates BOTH frozen layers AND overflow HashMap to capture all entries.
pub fn average_strategy(state: &CompactCfrState) -> FxHashMap<u64, Vec<f32>> {
    let mut result = FxHashMap::with_capacity_and_hasher(state.len(), Default::default());

    // Helper to normalize one entry's strategy sums
    let mut add_entry = |key: u64, n_actions: u8, strategy_offset: u64| {
        let n = n_actions as usize;
        let base = strategy_offset as usize;
        let mut total: f32 = 0.0;
        for i in 0..n {
            total += state.strategy_arena.get(base + i);
        }
        let avg = if total > 0.0 {
            (0..n).map(|i| state.strategy_arena.get(base + i) / total).collect()
        } else {
            vec![1.0 / n as f32; n]
        };
        result.insert(key, avg);
    };

    // Frozen layers first
    if let Some(ref frozen) = state.frozen {
        for layer in &frozen.layers {
            for slot in 0..layer.len() {
                add_entry(
                    layer.keys.get(slot),
                    layer.n_actions.get(slot),
                    layer.offsets.get(slot),
                );
            }
        }
    }

    // Overflow HashMap
    for (&key, entry) in &state.index {
        add_entry(key, entry.n_actions, entry.strategy_offset);
    }

    result
}

/// Merge src CompactCfrState into dst by summing all regret and strategy entries.
pub fn merge_compact_state(dst: &mut CompactCfrState, src: &CompactCfrState) {
    // Helper: merge one entry's regret + strategy slices from src into dst.
    // For frozen entries, regret_offset == strategy_offset (parallel layouts);
    // for overflow HashMap entries, the two offsets are independent.
    //
    // Safety assertion: `find_or_add` returns whatever entry already exists
    // for `key`, even when its `n_actions` differs from the one we just
    // passed. If a stale entry shaped for k actions overlaps with an
    // incoming entry shaped for k' > k actions, the unchecked add below
    // would write past `dst_entry`'s slot into the next entry's region —
    // corrupting an unrelated info set. Catch the mismatch loudly here
    // rather than silently scribbling.
    fn merge_one(
        dst: &mut CompactCfrState,
        src: &CompactCfrState,
        key: u64,
        n_actions: u8,
        src_r_base: u64,
        src_s_base: u64,
    ) {
        let n = n_actions as usize;
        let dst_entry = dst.find_or_add(key, n_actions);
        assert_eq!(
            dst_entry.n_actions, n_actions,
            "merge_compact_state: n_actions mismatch for key {} (dst={}, src={}); \
             would corrupt adjacent entries",
            key, dst_entry.n_actions, n_actions,
        );
        let dst_r_base = dst_entry.regret_offset as usize;
        let dst_s_base = dst_entry.strategy_offset as usize;
        let src_r = src_r_base as usize;
        let src_s = src_s_base as usize;
        for i in 0..n {
            dst.regret_arena[dst_r_base + i] += src.regret_arena[src_r + i];
        }
        for i in 0..n {
            dst.strategy_arena[dst_s_base + i] += src.strategy_arena[src_s + i];
        }
    }

    // Frozen layers: iterate every slot. regret_offset == strategy_offset.
    if let Some(ref frozen) = src.frozen {
        for layer in &frozen.layers {
            for slot in 0..layer.len() {
                let off = layer.offsets.get(slot);
                merge_one(
                    dst,
                    src,
                    layer.keys.get(slot),
                    layer.n_actions.get(slot),
                    off,
                    off,
                );
            }
        }
    }

    // Overflow HashMap entries.
    for (&key, src_entry) in &src.index {
        merge_one(
            dst,
            src,
            key,
            src_entry.n_actions,
            src_entry.regret_offset,
            src_entry.strategy_offset,
        );
    }
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compact_basic() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 3);

        assert_eq!(entry.n_actions, 3);
        assert_eq!(state.regret(&entry, 0), 0.0);
        assert_eq!(state.strategy(&entry, 0), 0.0);
    }

    #[test]
    fn test_compact_regret_ops() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 3);

        state.add_regret(&entry, 0, 10.0);
        state.add_regret(&entry, 1, -5.0);
        state.add_regret(&entry, 2, 3.0);

        assert_eq!(state.regret(&entry, 0), 10.0);
        assert_eq!(state.regret(&entry, 1), -5.0);
        assert_eq!(state.regret(&entry, 2), 3.0);

        state.set_regret(&entry, 1, 0.0);
        assert_eq!(state.regret(&entry, 1), 0.0);
    }

    #[test]
    fn test_compact_strategy_ops() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 3);

        state.add_strategy(&entry, 0, 100.0);
        state.add_strategy(&entry, 1, 50.0);
        state.add_strategy(&entry, 2, 80.0);

        assert_eq!(state.strategy(&entry, 0), 100.0);
        assert_eq!(state.strategy(&entry, 1), 50.0);
        assert_eq!(state.strategy(&entry, 2), 80.0);
    }

    #[test]
    fn test_compact_regret_matching() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 3);

        state.set_regret(&entry, 0, 10.0);
        state.set_regret(&entry, 1, 20.0);
        state.set_regret(&entry, 2, 0.0);

        let mut out = [0.0f32; 3];
        regret_matching(&state, &entry, &mut out);

        assert!((out[0] - 1.0 / 3.0).abs() < 0.01);
        assert!((out[1] - 2.0 / 3.0).abs() < 0.01);
        assert!((out[2] - 0.0).abs() < 0.01);
    }

    #[test]
    fn test_compact_regret_matching_all_negative() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 3);

        state.set_regret(&entry, 0, -5.0);
        state.set_regret(&entry, 1, -10.0);
        state.set_regret(&entry, 2, -1.0);

        let mut out = [0.0f32; 3];
        regret_matching(&state, &entry, &mut out);

        for &p in &out {
            assert!((p - 1.0 / 3.0).abs() < 0.001);
        }
    }

    #[test]
    fn test_compact_accumulate_strategy_lcfr() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 2);

        let strat = [0.6f32, 0.4];
        accumulate_strategy(&mut state, &entry, &strat, 1.0, 100);

        assert!((state.strategy(&entry, 0) - 60.0).abs() < 1.0);
        assert!((state.strategy(&entry, 1) - 40.0).abs() < 1.0);
    }

    #[test]
    fn test_compact_regret_no_clamp() {
        // Regret arena was widened from i16 to f32 to eliminate the
        // halve-cycle precision loss that regressed Rust vs OCaml. Large
        // values must round-trip intact — no clamping at ±32767.
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 2);

        state.set_regret(&entry, 0, 50000.0);
        assert_eq!(state.regret(&entry, 0), 50000.0);

        state.set_regret(&entry, 0, -50000.0);
        assert_eq!(state.regret(&entry, 0), -50000.0);
    }

    #[test]
    fn test_compact_strategy_no_clamp() {
        // Strategy sums are f32 — they should NOT clamp at i16 limits
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 2);

        // Set strategy beyond i16 range
        state.add_strategy(&entry, 0, 50000.0);
        assert_eq!(state.strategy(&entry, 0), 50000.0);

        state.add_strategy(&entry, 0, 1_000_000.0);
        assert_eq!(state.strategy(&entry, 0), 1_050_000.0);
    }

    #[test]
    fn test_compact_find_or_add_idempotent() {
        let mut state = CompactCfrState::new(100);
        let entry1 = state.find_or_add(42, 3);
        state.add_regret(&entry1, 0, 10.0);

        let entry2 = state.find_or_add(42, 3);
        assert_eq!(entry1.regret_offset, entry2.regret_offset);
        assert_eq!(entry1.strategy_offset, entry2.strategy_offset);
        assert_eq!(state.regret(&entry2, 0), 10.0);
    }

    #[test]
    fn test_compact_multiple_entries() {
        let mut state = CompactCfrState::new(100);

        let e1 = state.find_or_add(1, 3);
        let e2 = state.find_or_add(2, 2);
        let e3 = state.find_or_add(3, 4);

        state.add_regret(&e1, 0, 10.0);
        state.add_regret(&e2, 0, 20.0);
        state.add_regret(&e3, 0, 30.0);

        // Verify no cross-contamination
        assert_eq!(state.regret(&e1, 0), 10.0);
        assert_eq!(state.regret(&e2, 0), 20.0);
        assert_eq!(state.regret(&e3, 0), 30.0);

        assert_eq!(state.regret(&e1, 1), 0.0);
        assert_eq!(state.regret(&e1, 2), 0.0);
        assert_eq!(state.regret(&e2, 1), 0.0);
    }

    #[test]
    fn test_compact_average_strategy() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 3);

        state.add_strategy(&entry, 0, 60.0);
        state.add_strategy(&entry, 1, 30.0);
        state.add_strategy(&entry, 2, 10.0);

        let avg = average_strategy(&state);
        let probs = avg.get(&42).unwrap();
        assert!((probs[0] - 0.6).abs() < 0.01);
        assert!((probs[1] - 0.3).abs() < 0.01);
        assert!((probs[2] - 0.1).abs() < 0.01);
    }

    #[test]
    fn test_compact_merge() {
        let mut dst = CompactCfrState::new(100);
        let mut src = CompactCfrState::new(100);

        // Add to src
        let e_src = src.find_or_add(42, 3);
        src.add_regret(&e_src, 0, 10.0);
        src.add_regret(&e_src, 1, 5.0);
        src.add_strategy(&e_src, 0, 100.0);

        // Add overlapping entry to dst
        let e_dst = dst.find_or_add(42, 3);
        dst.add_regret(&e_dst, 0, 20.0);
        dst.add_regret(&e_dst, 1, -3.0);
        dst.add_strategy(&e_dst, 0, 50.0);

        // Add non-overlapping
        let e_src2 = src.find_or_add(99, 2);
        src.add_regret(&e_src2, 0, 7.0);

        merge_compact_state(&mut dst, &src);

        let e42 = *dst.index.get(&42).unwrap();
        assert!((dst.regret(&e42, 0) - 30.0).abs() < 1.0);
        assert!((dst.regret(&e42, 1) - 2.0).abs() < 1.0);
        assert!((dst.strategy(&e42, 0) - 150.0).abs() < 1.0);

        let e99 = *dst.index.get(&99).unwrap();
        assert!((dst.regret(&e99, 0) - 7.0).abs() < 1.0);
    }

    #[test]
    fn test_compact_lazy_dcfr() {
        use crate::cfr_state::DcfrTable;

        let mut state = CompactCfrState::new(100);
        let mut dcfr_table = DcfrTable::new();
        dcfr_table.ensure_epoch(3);

        // Create entry at epoch 0
        let entry = state.find_or_add(42, 3);
        state.set_regret(&entry, 0, 100.0);
        state.set_regret(&entry, 1, -50.0);
        state.set_regret(&entry, 2, 30.0);
        state.add_strategy(&entry, 0, 200.0);
        state.add_strategy(&entry, 1, 150.0);
        state.add_strategy(&entry, 2, 80.0);

        // Apply lazy DCFR by accessing at epoch 3
        let updated_entry = state.find_or_add_lazy_dcfr(42, 3, 3, &dcfr_table);

        // Verify discount was applied (positive regrets should be slightly less,
        // negative regret should be significantly less in magnitude)
        assert!(state.regret(&updated_entry, 0) <= 100.0);
        assert!(state.regret(&updated_entry, 0) > 90.0); // pos factor is ~0.999
        assert!(state.regret(&updated_entry, 1).abs() < 50.0); // neg factor = 0.5^3 = 0.125
        assert_eq!(updated_entry.last_discount_epoch, 3);
    }

    #[test]
    fn test_compact_size_savings() {
        // CompactEntry grew from 16 to 24 bytes when offsets widened from u32
        // to u64 — the u32 ceiling was hit at ~26% of P1 strategies at iter
        // 40M (silent offset wrap, see CompactEntry comment). 24 bytes is
        // still well below the per-Vec heap-overhead of the pre-arena layout.
        assert!(std::mem::size_of::<CompactEntry>() <= 24,
            "CompactEntry should be <= 24 bytes, got {}",
            std::mem::size_of::<CompactEntry>());
    }

    #[test]
    fn test_compact_lcfr_large_strategy_sums() {
        // This is the core regression test for the i16 saturation bug.
        // With LCFR, strategy sums grow as ~iter * probability. At 25M iterations,
        // strategy sums can reach millions. f32 handles this; i16 would saturate.
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 2);

        // Simulate 25M iterations of LCFR accumulation
        // At iter 25_000_000, weight = 25_000_000 * strat[0] = 25_000_000 * 0.6 = 15_000_000
        let strat = [0.6f32, 0.4];
        accumulate_strategy(&mut state, &entry, &strat, 1.0, 25_000_000);

        // With f32: strat[0] ~ 15_000_000, strat[1] ~ 10_000_000
        // f32 has ~7 digits of precision, so tolerance = 2.0 at 15M scale
        assert!((state.strategy(&entry, 0) - 15_000_000.0).abs() < 2.0);
        assert!((state.strategy(&entry, 1) - 10_000_000.0).abs() < 2.0);

        // Average strategy should be 60/40
        let avg = average_strategy(&state);
        let probs = avg.get(&42).unwrap();
        assert!((probs[0] - 0.6).abs() < 0.001);
        assert!((probs[1] - 0.4).abs() < 0.001);
    }

    #[test]
    fn test_halve_regrets() {
        // Regret storage is f32; halve is exact /2.0 with no integer
        // truncation (the prior i16 path truncated 32767/2 to 16383 and
        // 8191; both now round to mathematical halves).
        let mut state = CompactCfrState::new(100);
        let e1 = state.find_or_add(1, 3);
        let e2 = state.find_or_add(2, 2);

        state.set_regret(&e1, 0, 30000.0);
        state.set_regret(&e1, 1, -20000.0);
        state.set_regret(&e1, 2, 100.0);
        state.set_regret(&e2, 0, 32767.0);
        state.set_regret(&e2, 1, -32767.0);

        state.halve_regrets();

        assert_eq!(state.regret(&e1, 0), 15000.0);
        assert_eq!(state.regret(&e1, 1), -10000.0);
        assert_eq!(state.regret(&e1, 2), 50.0);
        assert_eq!(state.regret(&e2, 0), 16383.5);
        assert_eq!(state.regret(&e2, 1), -16383.5);

        state.halve_regrets();
        assert_eq!(state.regret(&e1, 0), 7500.0);
        assert_eq!(state.regret(&e2, 0), 16383.5 / 2.0);
    }

    /// Fingerprint must be deterministic and well-mixed: identical keys
    /// hash identically; distinct keys collide very rarely. We test a
    /// small batch to catch any accidental seed dependency or trivial
    /// XOR-fold that would collide on patterned keys.
    #[test]
    fn test_fingerprint_deterministic_and_mixed() {
        // Same key -> same fp every call.
        for &k in &[0u64, 1, 42, 0xDEAD_BEEF_CAFE_BABE, u64::MAX] {
            let a = fingerprint(k);
            let b = fingerprint(k);
            assert_eq!(a, b, "fingerprint not deterministic for {:x}", k);
        }

        // Patterned keys that a trivial xor-fold (k as u32 ^ (k >> 32) as u32)
        // would collide on. e.g. (a, a << 32 | a) → xor-fold gives 0 for both.
        // MurmurHash3 finalizer shatters them.
        let f0 = fingerprint(0);
        let f1 = fingerprint(0x12345678_12345678);
        let f2 = fingerprint(0xAAAA_5555_AAAA_5555);
        let f3 = fingerprint(0x5555_AAAA_5555_AAAA);
        let set = [f0, f1, f2, f3];
        // No pair collides on this small set.
        for i in 0..set.len() {
            for j in (i + 1)..set.len() {
                assert_ne!(set[i], set[j], "patterned-key collision at {},{}", i, j);
            }
        }
    }

    /// Freezing into a frozen layer must produce a layer that carries
    /// its fingerprint sidecar AND that round-trips every key correctly
    /// via the lookup fast path.
    #[test]
    fn test_freeze_lookup_uses_fingerprint() {
        let mut state = CompactCfrState::new(1024);
        // Seed the overflow map with a deterministic key set.
        let keys: Vec<u64> = (0u64..500).map(|i| i.wrapping_mul(0x9E37_79B9_7F4A_7C15)).collect();
        for &k in &keys {
            let e = state.find_or_add(k, 3);
            state.add_regret(&e, 0, k as f32 % 100.0);
        }

        state.freeze();

        // Assert fp sidecar is present + sized correctly. Scope the
        // immutable borrow so the round-trip below can take &mut state.
        {
            let frozen = state.frozen.as_ref().expect("freeze must produce a layer");
            assert_eq!(frozen.layers.len(), 1, "single freeze -> one layer");
            let layer = &frozen.layers[0];
            let fp = layer.fingerprints.as_ref()
                .expect("freshly frozen layer must carry fingerprints");
            assert_eq!(fp.len(), layer.len(), "fp length matches keys length");

            // Unknown keys reliably miss on the frozen layer directly.
            // FPR is ~2^-32 per probe — 100 trials virtually never produce
            // a false fingerprint hit, and even if one does, the full-key
            // compare downstream catches it.
            for k in keys.iter().take(100).map(|k| k.wrapping_add(1)) {
                let result = layer.lookup(k);
                assert!(result.is_none(),
                    "unknown key {:x} unexpectedly hit slot {:?}", k, result);
            }
        }

        // Every original key still looks up; the regret survives the freeze.
        for &k in &keys {
            let entry = state.find_or_add(k, 3);
            assert_eq!(entry.n_actions, 3);
            let r = state.regret(&entry, 0);
            assert_eq!(r, k as f32 % 100.0, "regret roundtrip for key {:x}", k);
        }
    }

    /// A FrozenLayer with `fingerprints = None` (i.e. a layer loaded from
    /// an on-disk format that predates the fp sidecar) must still serve
    /// lookups correctly — falling through to the full-key compare.
    #[test]
    fn test_lookup_works_without_fingerprint_sidecar() {
        let mut state = CompactCfrState::new(64);
        let keys: Vec<u64> = (0u64..32).map(|i| 0x1000 + i * 7).collect();
        for &k in &keys {
            state.find_or_add(k, 2);
        }
        state.freeze();

        // Strip the fingerprint sidecar to simulate a legacy on-disk layer.
        let frozen = state.frozen.as_mut().unwrap();
        for layer in &mut frozen.layers {
            layer.fingerprints = None;
        }

        // Lookups still succeed for known keys.
        for &k in &keys {
            let entry = state.find_or_add(k, 2);
            assert_eq!(entry.n_actions, 2);
        }
    }

    /// Pruning disabled by default: freeze must keep every entry when
    /// thresholds are 0.0 (which is the constructor default).
    #[test]
    fn test_freeze_prune_disabled_keeps_all_entries() {
        let mut state = CompactCfrState::new(64);
        let keys: Vec<u64> = (0u64..50).map(|i| i.wrapping_mul(7) + 1).collect();
        for &k in &keys {
            let e = state.find_or_add(k, 3);
            // Make every entry "prune-worthy" by leaving regret=0 and strat=0.
            // With pruning disabled they must all survive anyway.
            let _ = state.regret(&e, 0);
        }
        state.freeze();

        let frozen = state.frozen.as_ref().expect("freeze produces a layer");
        assert_eq!(frozen.layers[0].len(), keys.len(),
            "no pruning -> all entries survive");
    }

    /// Pruning enabled: an entry with all-zero regret and all-zero strategy
    /// must be dropped from the new frozen layer; an entry with non-trivial
    /// regret or strategy must survive.
    #[test]
    fn test_freeze_prune_drops_dead_entries() {
        let mut state = CompactCfrState::new(64);
        state.set_freeze_prune_thresholds(1e-3, 1e-4);

        // Three entries:
        //   - K1: all-zero regret and strategy → should be PRUNED
        //   - K2: regret above threshold → must SURVIVE
        //   - K3: strategy above threshold → must SURVIVE
        let k_dead = 0xDEAD_0001u64;
        let k_regret = 0xDEAD_0002u64;
        let k_strat = 0xDEAD_0003u64;

        for &k in &[k_dead, k_regret, k_strat] {
            state.find_or_add(k, 3);
        }
        let e_regret = state.find_or_add(k_regret, 3);
        state.add_regret(&e_regret, 0, 1.0);
        let e_strat = state.find_or_add(k_strat, 3);
        state.add_strategy(&e_strat, 0, 1.0);

        state.freeze();

        let frozen = state.frozen.as_ref().expect("freeze produces a layer");
        let layer = &frozen.layers[0];
        assert_eq!(layer.len(), 2,
            "exactly 2 entries should survive pruning (the regretful + the strategic)");

        // Survivors must lookup back; the dead key must not be found.
        assert!(layer.lookup(k_regret).is_some(), "k_regret must survive");
        assert!(layer.lookup(k_strat).is_some(),  "k_strat must survive");
        assert!(layer.lookup(k_dead).is_none(),   "k_dead must be pruned");
    }

    /// Edge case: every entry is prune-worthy. freeze() must not panic on
    /// the resulting zero-key MPHF build; it just clears the overflow and
    /// skips the layer push.
    #[test]
    fn test_freeze_prune_all_entries_no_panic() {
        let mut state = CompactCfrState::new(64);
        state.set_freeze_prune_thresholds(1e-3, 1e-4);
        for i in 0..16u64 {
            state.find_or_add(i + 1, 3);
        }
        // All entries have 0 regret + 0 strategy -> all pruned.
        state.freeze();
        // Overflow drained; no frozen layer was pushed.
        assert!(state.index.is_empty(), "overflow must be drained");
        assert!(state.frozen.is_none(),
            "no entries survived -> no new layer pushed");
    }
}
