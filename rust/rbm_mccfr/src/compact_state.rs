/// Ultra-compact CFR state: arena-backed i16 storage for regrets + strategy sums.
///
/// Memory layout:
///   - FxHashMap<u64, CompactEntry> — 16 bytes per entry (offset + metadata)
///   - Vec<i16> arena — contiguous storage for all regret/strategy data
///
/// Each info set's data is laid out as:
///   [regret_0, ..., regret_{n-1}, strategy_0, ..., strategy_{n-1}]
///
/// i16 range is ±32767. For CFR+ (regrets floored to 0), regrets stay in
/// [0, ~10000] which fits easily. Strategy sums grow with iterations but
/// are periodically discounted by DCFR/LCFR, keeping them bounded.
///
/// When values would overflow i16, they are clamped (saturating arithmetic).
/// This is theoretically sound — bounded regret matching still converges.
///
/// Memory savings vs Vec<f32>:
///   - No per-entry heap allocation (24 bytes Vec overhead eliminated)
///   - i16 = 2 bytes vs f32 = 4 bytes (2x compression on data)
///   - Compact index entry: 8 bytes vs ~90 bytes current
///   - Total: ~3x less memory for same number of info sets

use rustc_hash::FxHashMap;

/// Compact index entry stored in the hash map.
/// Points into the arena where actual regret/strategy data lives.
/// Packed to 10 bytes: u64 offset + u8 n_actions + u8 epoch_hi (saves 1 byte vs 11).
#[derive(Clone, Copy, Debug)]
pub struct CompactEntry {
    /// Index into the arena Vec<i16> where this entry's data starts.
    pub arena_offset: u64,
    /// Number of actions at this info set (max 12) packed with epoch high byte.
    /// Low 4 bits = n_actions, high 4 bits = epoch bits 8-11.
    pub n_actions: u8,
    /// Last DCFR discount epoch applied to this entry.
    /// An epoch is `iteration / 1000`. u16 covers 65535 epochs = 65.5M iters.
    pub last_discount_epoch: u16,
}

/// Per-player compact CFR state with arena-backed i16 storage.
pub struct CompactCfrState {
    /// Index: info key -> compact entry metadata
    pub index: FxHashMap<u64, CompactEntry>,
    /// Arena: contiguous i16 storage for all regret + strategy data.
    /// Layout per entry: [regret_0..regret_{n-1}, strat_0..strat_{n-1}]
    pub arena: Vec<i16>,
}

impl CompactCfrState {
    pub fn new(capacity: usize) -> Self {
        // Pre-allocate arena assuming avg ~6 actions per info set, 12 i16 values each
        let arena_capacity = capacity * 12;
        Self {
            index: FxHashMap::with_capacity_and_hasher(capacity, Default::default()),
            arena: Vec::with_capacity(arena_capacity),
        }
    }

    pub fn len(&self) -> usize {
        self.index.len()
    }

    /// Get the regret value for action `i` at the given entry.
    #[inline(always)]
    pub fn regret(&self, entry: &CompactEntry, i: usize) -> f32 {
        self.arena[entry.arena_offset as usize + i] as f32
    }

    /// Get the strategy sum for action `i` at the given entry.
    #[inline(always)]
    pub fn strategy(&self, entry: &CompactEntry, i: usize) -> f32 {
        self.arena[entry.arena_offset as usize + entry.n_actions as usize + i] as f32
    }

    /// Add a delta to regret for action `i`. Clamps to i16 range.
    #[inline(always)]
    pub fn add_regret(&mut self, entry: &CompactEntry, i: usize, delta: f32) {
        let idx = entry.arena_offset as usize + i;
        let new = (self.arena[idx] as f32 + delta) as i32;
        self.arena[idx] = new.clamp(-32767, 32767) as i16;
    }

    /// Set regret for action `i`. Clamps to i16 range.
    #[inline(always)]
    pub fn set_regret(&mut self, entry: &CompactEntry, i: usize, v: f32) {
        let idx = entry.arena_offset as usize + i;
        self.arena[idx] = (v as i32).clamp(-32767, 32767) as i16;
    }

    /// Add a delta to strategy sum for action `i`. Clamps to i16 range.
    #[inline(always)]
    pub fn add_strategy(&mut self, entry: &CompactEntry, i: usize, delta: f32) {
        let idx = entry.arena_offset as usize + entry.n_actions as usize + i;
        let new = (self.arena[idx] as f32 + delta) as i32;
        self.arena[idx] = new.clamp(-32767, 32767) as i16;
    }

    /// Set strategy sum for action `i`. Clamps to i16 range.
    #[inline(always)]
    pub fn set_strategy(&mut self, entry: &CompactEntry, i: usize, v: f32) {
        let idx = entry.arena_offset as usize + entry.n_actions as usize + i;
        self.arena[idx] = (v as i32).clamp(-32767, 32767) as i16;
    }

    /// Get or create an entry for the given key. Returns a copy of the entry
    /// (it's Copy, only 11 bytes).
    #[inline]
    pub fn find_or_add(&mut self, key: u64, n_actions: u8) -> CompactEntry {
        if let Some(&entry) = self.index.get(&key) {
            return entry;
        }
        let offset = self.arena.len() as u64;
        let n = n_actions as usize * 2;
        self.arena.resize(self.arena.len() + n, 0i16);
        let entry = CompactEntry {
            arena_offset: offset,
            n_actions,
            last_discount_epoch: 0,
        };
        self.index.insert(key, entry);
        entry
    }

    /// Get or create an entry, applying lazy DCFR discount if the entry is stale.
    /// Returns a copy of the (possibly updated) entry.
    #[inline]
    pub fn find_or_add_lazy_dcfr(
        &mut self,
        key: u64,
        n_actions: u8,
        current_epoch: u16,
        dcfr_table: &super::cfr_state::DcfrTable,
    ) -> CompactEntry {
        // Check if entry exists
        if let Some(entry) = self.index.get_mut(&key) {
            if entry.last_discount_epoch < current_epoch {
                let (pos_factor, neg_factor, strat_factor) =
                    dcfr_table.discount_factors(entry.last_discount_epoch as u32, current_epoch as u32);
                let n = entry.n_actions as usize;
                let base = entry.arena_offset as usize;

                // Discount regrets
                for i in 0..n {
                    let r = self.arena[base + i] as f32;
                    let w = if r >= 0.0 { pos_factor } else { neg_factor };
                    let new = (r * w as f32) as i32;
                    self.arena[base + i] = new.clamp(-32767, 32767) as i16;
                }
                // Discount strategy sums
                for i in 0..n {
                    let s = self.arena[base + n + i] as f32;
                    let new = (s * strat_factor as f32) as i32;
                    self.arena[base + n + i] = new.clamp(-32767, 32767) as i16;
                }
                entry.last_discount_epoch = current_epoch;
            }
            return *entry;
        }

        // New entry
        let offset = self.arena.len() as u64;
        let n = n_actions as usize * 2;
        self.arena.resize(self.arena.len() + n, 0i16);
        let entry = CompactEntry {
            arena_offset: offset,
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
    let base = entry.arena_offset as usize;
    let mut pos_sum: f32 = 0.0;
    for i in 0..n {
        let r = (state.arena[base + i] as f32).max(0.0);
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
    let base = entry.arena_offset as usize;
    let mut pos_sum: f32 = 0.0;
    for i in 0..n {
        let r = state.arena[base + i] as f32;
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
    let base = entry.arena_offset as usize;
    let iter_weight = if lcfr_iter > 0 {
        weight * lcfr_iter as f32
    } else {
        weight
    };
    for i in 0..n {
        let idx = base + n + i;
        let new = (state.arena[idx] as f32 + iter_weight * strat[i]) as i32;
        state.arena[idx] = new.clamp(-32767, 32767) as i16;
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
        let base = entry.arena_offset as usize;
        for i in 0..n {
            let r = state.arena[base + i] as f32;
            let w = if r >= 0.0 { pos_weight } else { neg_weight };
            let new = (r * w) as i32;
            state.arena[base + i] = new.clamp(-32767, 32767) as i16;
        }
        for i in 0..n {
            let idx = base + n + i;
            let new = (state.arena[idx] as f32 * strat_weight) as i32;
            state.arena[idx] = new.clamp(-32767, 32767) as i16;
        }
    }
}

/// Average strategy: normalize strategy sums.
pub fn average_strategy(state: &CompactCfrState) -> FxHashMap<u64, Vec<f32>> {
    let mut result = FxHashMap::with_capacity_and_hasher(state.len(), Default::default());
    for (&key, entry) in &state.index {
        let n = entry.n_actions as usize;
        let base = entry.arena_offset as usize;
        let mut total: f32 = 0.0;
        for i in 0..n {
            total += state.arena[base + n + i] as f32;
        }
        let avg = if total > 0.0 {
            (0..n).map(|i| state.arena[base + n + i] as f32 / total).collect()
        } else {
            vec![1.0 / n as f32; n]
        };
        result.insert(key, avg);
    }
    result
}

/// Merge src CompactCfrState into dst by summing all regret and strategy entries.
pub fn merge_compact_state(dst: &mut CompactCfrState, src: &CompactCfrState) {
    for (&key, src_entry) in &src.index {
        let n = src_entry.n_actions as usize;
        let src_base = src_entry.arena_offset as usize;

        let dst_entry = dst.find_or_add(key, src_entry.n_actions);
        let dst_base = dst_entry.arena_offset as usize;

        // Sum regrets and strategy sums
        for i in 0..(n * 2) {
            let new = dst.arena[dst_base + i] as i32 + src.arena[src_base + i] as i32;
            dst.arena[dst_base + i] = new.clamp(-32767, 32767) as i16;
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

        // Try to set a value exceeding i16 range
        state.set_regret(&entry, 0, 50000.0);
        assert_eq!(state.regret(&entry, 0), 32767.0);

        state.set_regret(&entry, 0, -50000.0);
        assert_eq!(state.regret(&entry, 0), -32767.0);
    }

    #[test]
    fn test_compact_find_or_add_idempotent() {
        let mut state = CompactCfrState::new(100);
        let entry1 = state.find_or_add(42, 3);
        state.add_regret(&entry1, 0, 10.0);

        let entry2 = state.find_or_add(42, 3);
        assert_eq!(entry1.arena_offset, entry2.arena_offset);
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
}
