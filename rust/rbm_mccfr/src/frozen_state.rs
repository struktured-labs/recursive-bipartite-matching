/// Frozen CFR state using minimal perfect hash function (MPHF).
///
/// Replaces FxHashMap (~48 bytes/key) with MPHF (~2.1 bits/key) + flat arrays
/// (~15 bytes/key), cutting index memory by ~3x. Used after info set key space
/// stabilizes (typically after ~5M iterations).
///
/// Memory comparison at 1B entries:
///   FxHashMap index:  ~47 GB
///   Frozen index:     ~15 GB (MPHF + keys + metadata + offsets)
///   Arenas:           ~18 GB (same either way)
///   Total:            65 GB → 33 GB (50% reduction)

use ph::fmph;
use rustc_hash::FxHashMap;

use crate::cfr_state::DcfrTable;
use crate::compact_state::{CompactCfrState, CompactEntry};

/// Entry handle returned from frozen lookups.
/// Same layout as CompactEntry — callers don't need to change.
pub type FrozenEntry = CompactEntry;

/// Frozen CFR state: MPHF + flat arrays replace FxHashMap.
pub struct FrozenCfrState {
    /// Minimal perfect hash: key → slot in [0, n).
    /// ~2.1 bits/key with FMPHGO.
    mphf: fmph::GOFunction,

    /// Original keys in MPHF slot order for collision validation.
    /// keys[mphf.get(&k)] == k confirms the key was in the build set.
    keys: Vec<u64>,

    /// Per-slot metadata (flat arrays indexed by MPHF slot).
    n_actions: Vec<u8>,
    epochs: Vec<u16>,
    arena_offsets: Vec<u32>,

    /// Regret arena (i16), compacted in MPHF slot order.
    pub regret_arena: Vec<i16>,
    /// Strategy arena (f32), compacted in MPHF slot order.
    pub strategy_arena: Vec<f32>,

    /// Overflow: keys discovered after freeze.
    /// Expected <0.1% of frozen size.
    overflow: CompactCfrState,
}

impl FrozenCfrState {
    /// Freeze a CompactCfrState into a FrozenCfrState.
    ///
    /// Builds an MPHF from all keys, then compacts arenas into MPHF slot order.
    /// The old state is consumed (dropped) to free the FxHashMap memory.
    ///
    /// Takes ~30-60s for 1B keys. Memory spike: old + new arenas coexist briefly.
    pub fn freeze(old: CompactCfrState) -> Self {
        let n = old.index.len();
        eprintln!("[freeze] Building MPHF for {} entries...", n);
        let start = std::time::Instant::now();

        // Collect all keys
        let all_keys: Vec<u64> = old.index.keys().copied().collect();

        // Build MPHF
        let mphf = fmph::GOFunction::from_slice(&all_keys);
        eprintln!("[freeze] MPHF built in {:.1}s", start.elapsed().as_secs_f64());

        // Allocate flat arrays
        let mut keys = vec![0u64; n];
        let mut n_actions_arr = vec![0u8; n];
        let mut epochs_arr = vec![0u16; n];

        // First pass: compute total arena size and populate metadata
        let mut total_actions: usize = 0;
        for (&key, &entry) in &old.index {
            let slot = mphf.get(&key).unwrap_or(u64::MAX) as usize;
            debug_assert!(slot < n, "MPHF slot {} out of range for {} entries", slot, n);
            keys[slot] = key;
            n_actions_arr[slot] = entry.n_actions;
            epochs_arr[slot] = entry.last_discount_epoch;
            total_actions += entry.n_actions as usize;
        }

        // Compute arena offsets via prefix sum of n_actions
        let mut arena_offsets = Vec::with_capacity(n);
        let mut offset = 0u32;
        for &na in &n_actions_arr {
            arena_offsets.push(offset);
            offset += na as u32;
        }
        debug_assert_eq!(offset as usize, total_actions);

        // Compact arenas in MPHF slot order
        let mut regrets = vec![0i16; total_actions];
        let mut strategies = vec![0.0f32; total_actions];

        for (&key, &entry) in &old.index {
            let slot = mphf.get(&key).unwrap_or(u64::MAX) as usize;
            let new_base = arena_offsets[slot] as usize;
            let old_r_base = entry.regret_offset as usize;
            let old_s_base = entry.strategy_offset as usize;
            let na = entry.n_actions as usize;

            for i in 0..na {
                regrets[new_base + i] = old.regret_arena.get(old_r_base + i);
                strategies[new_base + i] = old.strategy_arena.get(old_s_base + i);
            }
        }

        let elapsed = start.elapsed();
        let old_mb = (old.index.len() * 48 + old.regret_arena.len() * 2
            + old.strategy_arena.len() * 4) / 1024 / 1024;
        let new_mb = (n * 15 + regrets.len() * 2 + strategies.len() * 4) / 1024 / 1024;
        eprintln!(
            "[freeze] Complete in {:.1}s: {} entries, ~{}MB → ~{}MB ({:.0}% reduction)",
            elapsed.as_secs_f64(), n, old_mb, new_mb,
            (1.0 - new_mb as f64 / old_mb as f64) * 100.0
        );

        // Drop old state explicitly (frees FxHashMap)
        drop(old);

        FrozenCfrState {
            mphf,
            keys,
            n_actions: n_actions_arr,
            epochs: epochs_arr,
            arena_offsets,
            regret_arena: regrets,
            strategy_arena: strategies,
            overflow: CompactCfrState::new(1024),
        }
    }

    /// Number of frozen entries (excludes overflow).
    pub fn len(&self) -> usize {
        self.keys.len() + self.overflow.len()
    }

    /// Look up a key. Returns (slot, is_overflow) or creates in overflow.
    #[inline]
    fn lookup_slot(&self, key: u64) -> Option<usize> {
        let slot = self.mphf.get(&key).unwrap_or(u64::MAX) as usize;
        if slot < self.keys.len() && self.keys[slot] == key {
            Some(slot)
        } else {
            None
        }
    }

    /// Get or create an entry, with lazy DCFR discount for frozen entries.
    #[inline]
    pub fn find_or_add_lazy_dcfr(
        &mut self,
        key: u64,
        n_actions: u8,
        current_epoch: u16,
        dcfr_table: &DcfrTable,
    ) -> FrozenEntry {
        // Fast path: MPHF lookup
        if let Some(slot) = self.lookup_slot(key) {
            // Apply lazy discount if stale
            if self.epochs[slot] < current_epoch {
                self.apply_discount(slot, current_epoch, dcfr_table);
            }
            return FrozenEntry {
                regret_offset: self.arena_offsets[slot],
                strategy_offset: self.arena_offsets[slot],
                n_actions: self.n_actions[slot],
                last_discount_epoch: self.epochs[slot],
            };
        }

        // Slow path: overflow
        self.overflow.find_or_add_lazy_dcfr(key, n_actions, current_epoch, dcfr_table)
    }

    /// Get or create an entry (no DCFR).
    #[inline]
    pub fn find_or_add(&mut self, key: u64, n_actions: u8) -> FrozenEntry {
        if let Some(slot) = self.lookup_slot(key) {
            return FrozenEntry {
                regret_offset: self.arena_offsets[slot],
                strategy_offset: self.arena_offsets[slot],
                n_actions: self.n_actions[slot],
                last_discount_epoch: self.epochs[slot],
            };
        }
        self.overflow.find_or_add(key, n_actions)
    }

    #[inline]
    fn apply_discount(&mut self, slot: usize, current_epoch: u16, dcfr_table: &DcfrTable) {
        let (pos_factor, neg_factor, strat_factor) =
            dcfr_table.discount_factors(self.epochs[slot] as u32, current_epoch as u32);
        let n = self.n_actions[slot] as usize;
        let base = self.arena_offsets[slot] as usize;

        for i in 0..n {
            let r = self.regret_arena[base + i] as f32;
            let w = if r >= 0.0 { pos_factor } else { neg_factor };
            self.regret_arena[base + i] = ((r * w as f32) as i32).clamp(-32767, 32767) as i16;
        }
        for i in 0..n {
            self.strategy_arena[base + i] *= strat_factor as f32;
        }
        self.epochs[slot] = current_epoch;
    }

    /// Read regret for action i. Dispatches to frozen or overflow arena.
    #[inline(always)]
    pub fn regret(&self, entry: &FrozenEntry, i: usize) -> f32 {
        let idx = entry.regret_offset as usize + i;
        // If offset is in frozen range, use frozen arena; else overflow
        if idx < self.regret_arena.len() {
            self.regret_arena[idx] as f32
        } else {
            self.overflow.regret(entry, i)
        }
    }

    /// Write regret for action i.
    #[inline(always)]
    pub fn add_regret(&mut self, entry: &FrozenEntry, i: usize, delta: f32) {
        let idx = entry.regret_offset as usize + i;
        if idx < self.regret_arena.len() {
            let new = (self.regret_arena[idx] as f32 + delta) as i32;
            self.regret_arena[idx] = new.clamp(-32767, 32767) as i16;
        } else {
            self.overflow.add_regret(entry, i, delta);
        }
    }

    /// Set regret for action i.
    #[inline(always)]
    pub fn set_regret(&mut self, entry: &FrozenEntry, i: usize, v: f32) {
        let idx = entry.regret_offset as usize + i;
        if idx < self.regret_arena.len() {
            self.regret_arena[idx] = (v as i32).clamp(-32767, 32767) as i16;
        } else {
            self.overflow.set_regret(entry, i, v);
        }
    }

    /// Read strategy sum for action i.
    #[inline(always)]
    pub fn strategy(&self, entry: &FrozenEntry, i: usize) -> f32 {
        let idx = entry.strategy_offset as usize + i;
        if idx < self.strategy_arena.len() {
            self.strategy_arena[idx]
        } else {
            self.overflow.strategy(entry, i)
        }
    }

    /// Add to strategy sum for action i.
    #[inline(always)]
    pub fn add_strategy(&mut self, entry: &FrozenEntry, i: usize, delta: f32) {
        let idx = entry.strategy_offset as usize + i;
        if idx < self.strategy_arena.len() {
            self.strategy_arena[idx] += delta;
        } else {
            self.overflow.add_strategy(entry, i, delta);
        }
    }

    /// Halve all regrets (both frozen and overflow arenas).
    pub fn halve_regrets(&mut self) {
        for r in self.regret_arena.iter_mut() {
            *r /= 2;
        }
        self.overflow.halve_regrets();
    }

    /// Overflow stats for monitoring.
    pub fn overflow_len(&self) -> usize {
        self.overflow.len()
    }
}

/// Regret matching from a frozen entry — same math as compact_state.
#[inline]
pub fn regret_matching(state: &FrozenCfrState, entry: &FrozenEntry, strat: &mut [f32]) {
    let n = entry.n_actions as usize;
    let base = entry.regret_offset as usize;
    let mut total = 0.0f32;

    if base + n <= state.regret_arena.len() {
        // Frozen path
        for i in 0..n {
            let r = state.regret_arena[base + i] as f32;
            let p = if r > 0.0 { r } else { 0.0 };
            strat[i] = p;
            total += p;
        }
    } else {
        // Overflow path
        for i in 0..n {
            let r = state.overflow.regret(entry, i);
            let p = if r > 0.0 { r } else { 0.0 };
            strat[i] = p;
            total += p;
        }
    }

    if total > 0.0 {
        let inv = 1.0 / total;
        for s in strat[..n].iter_mut() {
            *s *= inv;
        }
    } else {
        let uniform = 1.0 / n as f32;
        for s in strat[..n].iter_mut() {
            *s = uniform;
        }
    }
}

/// Regret matching with pruning from a frozen entry.
#[inline]
pub fn regret_matching_pruned(
    state: &FrozenCfrState,
    entry: &FrozenEntry,
    prune_threshold: f32,
    strat: &mut [f32],
    pruned: &mut [bool],
) {
    let n = entry.n_actions as usize;
    let base = entry.regret_offset as usize;
    let mut total = 0.0f32;

    if base + n <= state.regret_arena.len() {
        for i in 0..n {
            let r = state.regret_arena[base + i] as f32;
            if r < prune_threshold {
                strat[i] = 0.0;
                pruned[i] = true;
            } else {
                let p = if r > 0.0 { r } else { 0.0 };
                strat[i] = p;
                total += p;
                pruned[i] = false;
            }
        }
    } else {
        for i in 0..n {
            let r = state.overflow.regret(entry, i);
            if r < prune_threshold {
                strat[i] = 0.0;
                pruned[i] = true;
            } else {
                let p = if r > 0.0 { r } else { 0.0 };
                strat[i] = p;
                total += p;
                pruned[i] = false;
            }
        }
    }

    if total > 0.0 {
        let inv = 1.0 / total;
        for i in 0..n {
            if !pruned[i] {
                strat[i] *= inv;
            }
        }
    } else {
        let mut n_unpruned = 0usize;
        for i in 0..n {
            if !pruned[i] { n_unpruned += 1; }
        }
        if n_unpruned > 0 {
            let uniform = 1.0 / n_unpruned as f32;
            for i in 0..n {
                strat[i] = if pruned[i] { 0.0 } else { uniform };
            }
        } else {
            let uniform = 1.0 / n as f32;
            for i in 0..n {
                strat[i] = uniform;
                pruned[i] = false;
            }
        }
    }
}

/// Accumulate strategy sums (LCFR-weighted) for a frozen entry.
#[inline]
pub fn accumulate_strategy(
    state: &mut FrozenCfrState,
    entry: &FrozenEntry,
    strat: &[f32],
    weight: f32,
    lcfr_iter: u32,
) {
    let n = entry.n_actions as usize;
    let base = entry.strategy_offset as usize;
    let w = if lcfr_iter > 0 { lcfr_iter as f32 * weight } else { weight };

    if base + n <= state.strategy_arena.len() {
        for i in 0..n {
            state.strategy_arena[base + i] += strat[i] * w;
        }
    } else {
        for i in 0..n {
            state.overflow.add_strategy(entry, i, strat[i] * w);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_freeze_and_lookup() {
        let mut state = CompactCfrState::new(100);

        // Add some entries
        for i in 0..50u64 {
            let entry = state.find_or_add(i * 1000 + 42, 3);
            state.add_regret(&entry, 0, 10.0);
            state.add_regret(&entry, 1, -5.0);
            state.add_strategy(&entry, 0, 100.0);
        }

        assert_eq!(state.len(), 50);

        // Freeze
        let frozen = FrozenCfrState::freeze(state);
        assert_eq!(frozen.len(), 50);
        assert_eq!(frozen.overflow_len(), 0);

        // All original keys should be findable (immutable find_or_add
        // won't create overflow since all keys are frozen)
        // Use a mutable reference for the API but no overflow should occur
        let mut frozen = frozen;
        for i in 0..50u64 {
            let key = i * 1000 + 42;
            let entry = frozen.find_or_add(key, 3);
            assert_eq!(entry.n_actions, 3);
            // Regrets should be preserved
            let r0 = frozen.regret(&entry, 0);
            assert!((r0 - 10.0).abs() < 1.0, "regret 0 should be ~10, got {}", r0);
        }

        // New keys go to overflow
        let new_entry = frozen.find_or_add(999999, 2);
        assert_eq!(new_entry.n_actions, 2);
        assert_eq!(frozen.overflow_len(), 1);
    }

    #[test]
    fn test_freeze_regret_matching() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 3);
        state.add_regret(&entry, 0, 10.0);
        state.add_regret(&entry, 1, 20.0);
        state.add_regret(&entry, 2, -5.0);
        state.add_strategy(&entry, 0, 50.0);

        let mut frozen = FrozenCfrState::freeze(state);
        let entry = frozen.find_or_add(42, 3);

        let mut strat = [0.0f32; 12];
        regret_matching(&frozen, &entry, &mut strat[..3]);

        // Only positive regrets contribute: 10 + 20 = 30
        assert!((strat[0] - 10.0/30.0).abs() < 1e-5);
        assert!((strat[1] - 20.0/30.0).abs() < 1e-5);
        assert!(strat[2] < 1e-5); // negative regret → 0
    }

    #[test]
    fn test_freeze_halve_regrets() {
        let mut state = CompactCfrState::new(100);
        let entry = state.find_or_add(42, 2);
        state.add_regret(&entry, 0, 100.0);
        state.add_regret(&entry, 1, 200.0);

        let mut frozen = FrozenCfrState::freeze(state);
        frozen.halve_regrets();

        let entry = frozen.find_or_add(42, 2);
        assert!((frozen.regret(&entry, 0) - 50.0).abs() < 1.0);
        assert!((frozen.regret(&entry, 1) - 100.0).abs() < 1.0);
    }
}
