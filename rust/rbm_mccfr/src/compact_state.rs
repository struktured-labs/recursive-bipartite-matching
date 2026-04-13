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
    pub regret_offset: u32,
    /// Index into the strategy_arena Vec<f32> where this entry's strategy sums start.
    pub strategy_offset: u32,
    /// Number of actions at this info set (max 12).
    pub n_actions: u8,
    /// Last DCFR discount epoch applied to this entry.
    /// An epoch is `iteration / 1000`. u16 covers 65535 epochs = 65.5M iters.
    pub last_discount_epoch: u16,
}

/// A single immutable MPHF layer with flat metadata arrays.
pub struct FrozenLayer {
    mphf: fmph::GOFunction,
    keys: Arena<u64>,
    n_actions: Arena<u8>,
    epochs: Arena<u16>,
    offsets: Arena<u32>,
}

impl FrozenLayer {
    fn len(&self) -> usize {
        self.keys.len()
    }

    /// Look up a key in this layer. Returns slot index if found.
    #[inline]
    fn lookup(&self, key: u64) -> Option<usize> {
        let slot = self.mphf.get(&key).unwrap_or(u64::MAX) as usize;
        if slot < self.keys.len() && self.keys.get(slot) == key {
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
    /// Regret arena: contiguous i16 storage.
    pub regret_arena: Arena<i16>,
    /// Strategy arena: contiguous f32 storage.
    pub strategy_arena: Arena<f32>,
    /// Optional frozen MPHF index. When set, find_or_add checks MPHF first.
    pub(crate) frozen: Option<FrozenIndex>,
    /// Player ID for mmap file naming.
    pub(crate) player_id: u8,
    pub(crate) use_mmap: bool,
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
        }
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

        eprintln!(
            "[freeze] Building MPHF for {} overflow entries ({} existing layers, {} frozen total)...",
            overflow_len, n_layers, total_frozen
        );
        let start = std::time::Instant::now();

        // Build MPHF from overflow keys only
        let all_keys: Vec<u64> = self.index.keys().copied().collect();
        let mphf = fmph::GOFunction::from_slice(&all_keys);

        // Build flat arrays for this layer
        let n = overflow_len;
        let mut keys = vec![0u64; n];
        let mut n_actions_arr = vec![0u8; n];
        let mut epochs_arr = vec![0u16; n];
        let mut offsets_arr = vec![0u32; n];

        for (&key, &entry) in &self.index {
            let slot = mphf.get(&key).unwrap_or(u64::MAX) as usize;
            keys[slot] = key;
            n_actions_arr[slot] = entry.n_actions;
            epochs_arr[slot] = entry.last_discount_epoch;
            offsets_arr[slot] = entry.regret_offset;
        }

        let old_overflow_bytes = overflow_len * 48;
        self.index.clear();
        self.index.shrink_to(1024);

        let new_layer_bytes = n * 15;

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
        let (k, na, ep, off) = if self.use_mmap {
            let dir = std::path::Path::new(".");
            let p = self.player_id;
            (
                vec_to_mmap(keys, &dir.join(format!("frozen_keys_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(n_actions_arr, &dir.join(format!("frozen_na_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(epochs_arr, &dir.join(format!("frozen_ep_p{}_L{}.bin", p, layer_id))),
                vec_to_mmap(offsets_arr, &dir.join(format!("frozen_off_p{}_L{}.bin", p, layer_id))),
            )
        } else {
            (Arena::Mem(keys), Arena::Mem(n_actions_arr), Arena::Mem(epochs_arr), Arena::Mem(offsets_arr))
        };

        let new_layer = FrozenLayer {
            mphf,
            keys: k,
            n_actions: na,
            epochs: ep,
            offsets: off,
        };

        // Push new layer
        match &mut self.frozen {
            Some(f) => f.layers.push(new_layer),
            None => self.frozen = Some(FrozenIndex { layers: vec![new_layer] }),
        }

        eprintln!(
            "[freeze] Complete in {:.1}s: layer {} with {} entries. Overflow {}MB freed, layer = {}MB",
            start.elapsed().as_secs_f64(),
            layer_id,
            n,
            old_overflow_bytes / 1024 / 1024,
            new_layer_bytes / 1024 / 1024,
        );
    }

    /// Get the regret value for action `i` at the given entry.
    #[inline(always)]
    pub fn regret(&self, entry: &CompactEntry, i: usize) -> f32 {
        self.regret_arena.get(entry.regret_offset as usize + i) as f32
    }

    /// Get the strategy sum for action `i` at the given entry.
    #[inline(always)]
    pub fn strategy(&self, entry: &CompactEntry, i: usize) -> f32 {
        self.strategy_arena.get(entry.strategy_offset as usize + i)
    }

    /// Add a delta to regret for action `i`. Clamps to i16 range.
    #[inline(always)]
    pub fn add_regret(&mut self, entry: &CompactEntry, i: usize, delta: f32) {
        let idx = entry.regret_offset as usize + i;
        let new = (self.regret_arena.get(idx) as f32 + delta) as i32;
        self.regret_arena.set(idx, new.clamp(-32767, 32767) as i16);
    }

    /// Set regret for action `i`. Clamps to i16 range.
    #[inline(always)]
    pub fn set_regret(&mut self, entry: &CompactEntry, i: usize, v: f32) {
        let idx = entry.regret_offset as usize + i;
        self.regret_arena.set(idx, (v as i32).clamp(-32767, 32767) as i16);
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

    /// Halve all regrets in the arena.
    pub fn halve_regrets(&mut self) {
        for r in self.regret_arena.iter_mut() {
            *r /= 2;
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
        let regret_offset = self.regret_arena.len() as u32;
        let strategy_offset = self.strategy_arena.len() as u32;
        let n = n_actions as usize;
        self.regret_arena.resize(self.regret_arena.len() + n, 0i16);
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
                            let r = self.regret_arena.get(base + i) as f32;
                            let w = if r >= 0.0 { pos_factor } else { neg_factor };
                            self.regret_arena.set(base + i, ((r * w as f32) as i32).clamp(-32767, 32767) as i16);
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
                    let r = self.regret_arena[r_base + i] as f32;
                    let w = if r >= 0.0 { pos_factor } else { neg_factor };
                    self.regret_arena[r_base + i] = ((r * w as f32) as i32).clamp(-32767, 32767) as i16;
                }
                for i in 0..n {
                    self.strategy_arena[s_base + i] *= strat_factor as f32;
                }
                entry.last_discount_epoch = current_epoch;
            }
            return *entry;
        }

        // New entry (into HashMap)
        let regret_offset = self.regret_arena.len() as u32;
        let strategy_offset = self.strategy_arena.len() as u32;
        let n = n_actions as usize;
        self.regret_arena.resize(self.regret_arena.len() + n, 0i16);
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
        // Discount regrets (i16)
        for i in 0..n {
            let r = state.regret_arena[r_base + i] as f32;
            let w = if r >= 0.0 { pos_weight } else { neg_weight };
            let new = (r * w) as i32;
            state.regret_arena[r_base + i] = new.clamp(-32767, 32767) as i16;
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
    let mut add_entry = |key: u64, n_actions: u8, strategy_offset: u32| {
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
    for (&key, src_entry) in &src.index {
        let n = src_entry.n_actions as usize;
        let src_r_base = src_entry.regret_offset as usize;
        let src_s_base = src_entry.strategy_offset as usize;

        let dst_entry = dst.find_or_add(key, src_entry.n_actions);
        let dst_r_base = dst_entry.regret_offset as usize;
        let dst_s_base = dst_entry.strategy_offset as usize;

        // Sum regrets (i16, clamped)
        for i in 0..n {
            let new = dst.regret_arena[dst_r_base + i] as i32 + src.regret_arena[src_r_base + i] as i32;
            dst.regret_arena[dst_r_base + i] = new.clamp(-32767, 32767) as i16;
        }
        // Sum strategy sums (f32, no clamping)
        for i in 0..n {
            dst.strategy_arena[dst_s_base + i] += src.strategy_arena[src_s_base + i];
        }
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
    fn test_compact_i16_clamp() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 2);

        // Try to set a regret value exceeding i16 range
        state.set_regret(&entry, 0, 50000.0);
        assert_eq!(state.regret(&entry, 0), 32767.0);

        state.set_regret(&entry, 0, -50000.0);
        assert_eq!(state.regret(&entry, 0), -32767.0);
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
        // Verify CompactEntry is small
        assert!(std::mem::size_of::<CompactEntry>() <= 16,
            "CompactEntry should be <= 16 bytes, got {}",
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
        let mut state = CompactCfrState::new(100);
        let e1 = state.find_or_add(1, 3);
        let e2 = state.find_or_add(2, 2);

        state.set_regret(&e1, 0, 30000.0);
        state.set_regret(&e1, 1, -20000.0);
        state.set_regret(&e1, 2, 100.0);
        state.set_regret(&e2, 0, 32767.0); // max i16
        state.set_regret(&e2, 1, -32767.0); // min i16

        state.halve_regrets();

        assert_eq!(state.regret(&e1, 0), 15000.0);
        assert_eq!(state.regret(&e1, 1), -10000.0);
        assert_eq!(state.regret(&e1, 2), 50.0);
        assert_eq!(state.regret(&e2, 0), 16383.0); // 32767 / 2 truncated
        assert_eq!(state.regret(&e2, 1), -16383.0);

        // Second halve
        state.halve_regrets();
        assert_eq!(state.regret(&e1, 0), 7500.0);
        assert_eq!(state.regret(&e2, 0), 8191.0);
    }
}
