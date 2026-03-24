/// CFR state: hash map from info key (u64) to packed regret+strategy floats.
/// Uses f32 instead of f64 — halves memory, sufficient precision for MCCFR.

use rustc_hash::FxHashMap;

/// Packed regret + strategy data for one info set.
/// Layout: [regret_0, ..., regret_{n-1}, strategy_0, ..., strategy_{n-1}]
#[derive(Clone)]
pub struct CfrEntry {
    pub data: Vec<f32>,
    pub n_actions: u8,
    /// Last DCFR discount epoch applied to this entry.
    /// An epoch is `iteration / 1000`.
    pub last_discount_epoch: u32,
}

impl CfrEntry {
    #[inline]
    pub fn new(n_actions: u8) -> Self {
        Self {
            data: vec![0.0; n_actions as usize * 2],
            n_actions,
            last_discount_epoch: 0,
        }
    }

    #[inline(always)]
    pub fn regret(&self, i: usize) -> f32 {
        self.data[i]
    }

    #[inline(always)]
    pub fn strategy(&self, i: usize) -> f32 {
        self.data[self.n_actions as usize + i]
    }

    #[inline(always)]
    pub fn set_regret(&mut self, i: usize, v: f32) {
        self.data[i] = v;
    }

    #[inline(always)]
    pub fn add_regret(&mut self, i: usize, v: f32) {
        self.data[i] += v;
    }

    #[inline(always)]
    pub fn add_strategy(&mut self, i: usize, v: f32) {
        self.data[self.n_actions as usize + i] += v;
    }
}

/// Per-player CFR state.
pub struct CfrState {
    pub entries: FxHashMap<u64, CfrEntry>,
}

impl CfrState {
    pub fn new(capacity: usize) -> Self {
        Self {
            entries: FxHashMap::with_capacity_and_hasher(capacity, Default::default()),
        }
    }

    /// Get or create an entry for the given key.
    #[inline]
    pub fn find_or_add(&mut self, key: u64, n_actions: u8) -> &mut CfrEntry {
        self.entries
            .entry(key)
            .or_insert_with(|| CfrEntry::new(n_actions))
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Get or create an entry, applying lazy DCFR discount if the entry is stale.
    #[inline]
    pub fn find_or_add_lazy_dcfr(
        &mut self,
        key: u64,
        n_actions: u8,
        current_epoch: u32,
        dcfr_table: &DcfrTable,
    ) -> &mut CfrEntry {
        let entry = self.entries.entry(key).or_insert_with(|| {
            let mut e = CfrEntry::new(n_actions);
            e.last_discount_epoch = current_epoch;
            e
        });
        if entry.last_discount_epoch < current_epoch {
            let (pos_factor, neg_factor, strat_factor) =
                dcfr_table.discount_factors(entry.last_discount_epoch, current_epoch);
            let n = entry.n_actions as usize;
            for i in 0..n {
                let r = entry.regret(i);
                let w = if r >= 0.0 { pos_factor } else { neg_factor };
                entry.set_regret(i, r * w as f32);
            }
            for i in 0..n {
                let s = entry.strategy(i);
                entry.data[n + i] = s * strat_factor as f32;
            }
            entry.last_discount_epoch = current_epoch;
        }
        entry
    }
}

/// Precomputed cumulative DCFR discount factors for lazy application.
///
/// Instead of scanning all hash table entries every 1000 iterations,
/// we store cumulative products so that when an entry is accessed after
/// N epochs, we can compute the combined discount in O(1).
pub struct DcfrTable {
    /// cumulative_pos[k] = product of pos_weight for epochs 1..=k
    cumulative_pos: Vec<f64>,
    /// cumulative_strat[k] = product of strat_weight for epochs 1..=k
    cumulative_strat: Vec<f64>,
}

impl DcfrTable {
    pub fn new() -> Self {
        Self {
            // epoch 0 has cumulative factor 1.0 (no discount applied yet)
            cumulative_pos: vec![1.0],
            cumulative_strat: vec![1.0],
        }
    }

    /// Ensure the table covers up to `epoch` (inclusive).
    pub fn ensure_epoch(&mut self, epoch: u32) {
        let epoch = epoch as usize;
        while self.cumulative_pos.len() <= epoch {
            let e = self.cumulative_pos.len() as f64; // this is the new epoch index
            let t = e * 1000.0; // iteration count at this epoch boundary
            let pos_weight = t / (t + 1.0);
            let strat_weight = (t / (t + 1.0)) * (t / (t + 1.0));
            let prev_pos = *self.cumulative_pos.last().unwrap();
            let prev_strat = *self.cumulative_strat.last().unwrap();
            self.cumulative_pos.push(prev_pos * pos_weight);
            self.cumulative_strat.push(prev_strat * strat_weight);
        }
    }

    /// Compute combined discount factors for an entry that was last updated
    /// at `from_epoch` and is now being accessed at `to_epoch`.
    ///
    /// Returns (pos_factor, neg_factor, strat_factor).
    #[inline]
    pub fn discount_factors(&self, from_epoch: u32, to_epoch: u32) -> (f64, f64, f64) {
        let from = from_epoch as usize;
        let to = to_epoch as usize;
        debug_assert!(to <= self.cumulative_pos.len() - 1);
        debug_assert!(from < to);

        let pos_factor = self.cumulative_pos[to] / self.cumulative_pos[from];
        let strat_factor = self.cumulative_strat[to] / self.cumulative_strat[from];

        // neg_weight is always 0.5 per epoch, so combined = 0.5^(to - from)
        let epochs_elapsed = (to - from) as f64;
        let neg_factor = 0.5f64.powf(epochs_elapsed);

        (pos_factor, neg_factor, strat_factor)
    }
}

/// Regret matching: convert cumulative regrets into a strategy.
/// Output written to `out` slice (avoids allocation).
#[inline]
pub fn regret_matching(entry: &CfrEntry, out: &mut [f32]) {
    let n = entry.n_actions as usize;
    let mut pos_sum: f32 = 0.0;
    for i in 0..n {
        let r = entry.regret(i).max(0.0);
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
    entry: &CfrEntry,
    threshold: f32,
    strat_out: &mut [f32],
    pruned_out: &mut [bool],
) {
    let n = entry.n_actions as usize;
    let mut pos_sum: f32 = 0.0;
    for i in 0..n {
        let r = entry.regret(i);
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
        // All pruned or zero — uniform over non-pruned
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
            // Everything pruned — uniform over all
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
pub fn accumulate_strategy(entry: &mut CfrEntry, strat: &[f32], weight: f32, lcfr_iter: u32) {
    let n = entry.n_actions as usize;
    let iter_weight = if lcfr_iter > 0 {
        weight * lcfr_iter as f32
    } else {
        weight
    };
    for i in 0..n {
        entry.add_strategy(i, iter_weight * strat[i]);
    }
}

/// DCFR discount: scale regrets and strategy sums.
pub fn apply_dcfr_discount(state: &mut CfrState, pos_weight: f32, neg_weight: f32, strat_weight: f32) {
    for entry in state.entries.values_mut() {
        let n = entry.n_actions as usize;
        for i in 0..n {
            let r = entry.regret(i);
            let w = if r >= 0.0 { pos_weight } else { neg_weight };
            entry.set_regret(i, r * w);
        }
        for i in 0..n {
            let s = entry.strategy(i);
            entry.data[n + i] = s * strat_weight;
        }
    }
}

/// Average strategy: normalize strategy sums.
pub fn average_strategy(state: &CfrState) -> FxHashMap<u64, Vec<f32>> {
    let mut result = FxHashMap::with_capacity_and_hasher(state.len(), Default::default());
    for (&key, entry) in &state.entries {
        let n = entry.n_actions as usize;
        let mut total: f32 = 0.0;
        for i in 0..n {
            total += entry.strategy(i);
        }
        let avg = if total > 0.0 {
            (0..n).map(|i| entry.strategy(i) / total).collect()
        } else {
            vec![1.0 / n as f32; n]
        };
        result.insert(key, avg);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_regret_matching_positive() {
        let mut entry = CfrEntry::new(3);
        entry.set_regret(0, 10.0);
        entry.set_regret(1, 20.0);
        entry.set_regret(2, 0.0);
        let mut out = [0.0f32; 3];
        regret_matching(&entry, &mut out);
        assert!((out[0] - 1.0 / 3.0).abs() < 0.01);
        assert!((out[1] - 2.0 / 3.0).abs() < 0.01);
        assert!((out[2] - 0.0).abs() < 0.01);
    }

    #[test]
    fn test_regret_matching_all_negative() {
        let mut entry = CfrEntry::new(3);
        entry.set_regret(0, -5.0);
        entry.set_regret(1, -10.0);
        entry.set_regret(2, -1.0);
        let mut out = [0.0f32; 3];
        regret_matching(&entry, &mut out);
        // Should be uniform
        for &p in &out {
            assert!((p - 1.0 / 3.0).abs() < 0.001);
        }
    }

    #[test]
    fn test_accumulate_strategy_lcfr() {
        let mut entry = CfrEntry::new(2);
        let strat = [0.6f32, 0.4];
        accumulate_strategy(&mut entry, &strat, 1.0, 100);
        assert!((entry.strategy(0) - 60.0).abs() < 0.01);
        assert!((entry.strategy(1) - 40.0).abs() < 0.01);
    }

    #[test]
    fn test_dcfr_table_single_epoch() {
        let mut table = DcfrTable::new();
        table.ensure_epoch(1);

        let (pos, neg, strat) = table.discount_factors(0, 1);
        // epoch 1: t=1000, pos_weight = 1000/1001, neg = 0.5, strat = (1000/1001)^2
        let expected_pos = 1000.0 / 1001.0;
        let expected_strat = expected_pos * expected_pos;
        assert!((pos - expected_pos).abs() < 1e-9);
        assert!((neg - 0.5).abs() < 1e-9);
        assert!((strat - expected_strat).abs() < 1e-9);
    }

    #[test]
    fn test_dcfr_table_multi_epoch() {
        let mut table = DcfrTable::new();
        table.ensure_epoch(3);

        // Discount from epoch 0 to epoch 3 should be the product of epochs 1,2,3
        let (pos_0_3, neg_0_3, strat_0_3) = table.discount_factors(0, 3);

        // Also compute stepwise and verify they match
        let (pos_0_1, neg_0_1, strat_0_1) = table.discount_factors(0, 1);
        let (pos_1_2, neg_1_2, strat_1_2) = table.discount_factors(1, 2);
        let (pos_2_3, neg_2_3, strat_2_3) = table.discount_factors(2, 3);

        let pos_product = pos_0_1 * pos_1_2 * pos_2_3;
        let neg_product = neg_0_1 * neg_1_2 * neg_2_3;
        let strat_product = strat_0_1 * strat_1_2 * strat_2_3;

        assert!((pos_0_3 - pos_product).abs() < 1e-9,
            "pos: {} vs {}", pos_0_3, pos_product);
        assert!((neg_0_3 - neg_product).abs() < 1e-9);
        assert!((strat_0_3 - strat_product).abs() < 1e-9,
            "strat: {} vs {}", strat_0_3, strat_product);
    }

    #[test]
    fn test_lazy_dcfr_matches_bulk() {
        // Verify that lazy DCFR produces the same result as bulk apply_dcfr_discount
        let mut state_bulk = CfrState::new(100);
        let mut state_lazy = CfrState::new(100);
        let mut dcfr_table = DcfrTable::new();

        let key = 42u64;

        // Set up identical entries in both states
        {
            let e = state_bulk.find_or_add(key, 3);
            e.set_regret(0, 100.0);
            e.set_regret(1, -50.0);
            e.set_regret(2, 30.0);
            e.add_strategy(0, 200.0);
            e.add_strategy(1, 150.0);
            e.add_strategy(2, 80.0);
        }
        {
            let e = state_lazy.find_or_add(key, 3);
            e.set_regret(0, 100.0);
            e.set_regret(1, -50.0);
            e.set_regret(2, 30.0);
            e.add_strategy(0, 200.0);
            e.add_strategy(1, 150.0);
            e.add_strategy(2, 80.0);
            e.last_discount_epoch = 0;
        }

        // Apply 3 epochs of bulk discount
        for epoch in 1..=3u32 {
            let t = (epoch * 1000) as f32;
            let pos_weight = t / (t + 1.0);
            let neg_weight = 0.5f32;
            let strat_weight = (t / (t + 1.0)).powf(2.0);
            apply_dcfr_discount(&mut state_bulk, pos_weight, neg_weight, strat_weight);
        }

        // Apply lazy discount in one shot
        dcfr_table.ensure_epoch(3);
        {
            let e = state_lazy.find_or_add_lazy_dcfr(key, 3, 3, &dcfr_table);
            // Just access to trigger the lazy discount
            let _ = e.regret(0);
        }

        let bulk_entry = state_bulk.entries.get(&key).unwrap();
        let lazy_entry = state_lazy.entries.get(&key).unwrap();

        for i in 0..3 {
            let bulk_r = bulk_entry.regret(i);
            let lazy_r = lazy_entry.regret(i);
            assert!(
                (bulk_r - lazy_r).abs() < 0.1,
                "regret[{}]: bulk={} lazy={}", i, bulk_r, lazy_r,
            );
        }
        for i in 0..3 {
            let bulk_s = bulk_entry.strategy(i);
            let lazy_s = lazy_entry.strategy(i);
            assert!(
                (bulk_s - lazy_s).abs() < 0.1,
                "strategy[{}]: bulk={} lazy={}", i, bulk_s, lazy_s,
            );
        }
    }
}
