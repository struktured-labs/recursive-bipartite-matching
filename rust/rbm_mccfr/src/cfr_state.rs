/// CFR state: hash map from info key (u64) to packed regret+strategy floats.
/// Uses f32 instead of f64 — halves memory, sufficient precision for MCCFR.

use rustc_hash::FxHashMap;

/// Packed regret + strategy data for one info set.
/// Layout: [regret_0, ..., regret_{n-1}, strategy_0, ..., strategy_{n-1}]
#[derive(Clone)]
pub struct CfrEntry {
    pub data: Vec<f32>,
    pub n_actions: u8,
}

impl CfrEntry {
    #[inline]
    pub fn new(n_actions: u8) -> Self {
        Self {
            data: vec![0.0; n_actions as usize * 2],
            n_actions,
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
}
