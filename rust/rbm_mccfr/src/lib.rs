//! RBM-MCCFR: High-performance MCCFR training engine for No-Limit Hold'em.
//!
//! This crate implements the performance-critical hot loop of Monte Carlo
//! Counterfactual Regret Minimization. It's designed to be called from OCaml
//! via C FFI, with OCaml handling the high-level orchestration (RBM distance,
//! clustering, Slumbot API) and Rust handling the tight inner loop.
//!
//! Uses CompactCfrState (arena-backed i16 storage) for ~3x memory savings
//! compared to the original Vec<f32> representation.

pub mod card;
pub mod config;
pub mod info_key;
pub mod cfr_state;
pub mod compact_state;
pub mod actions;

pub mod hand_eval;
pub mod hand_eval_fast;
pub mod traversal;

pub mod buckets;
pub mod checkpoint;
pub mod train;
pub mod slumbot;

pub mod tree;
pub mod hungarian;
pub mod rbm_distance;
pub mod rbm_buckets;
pub mod frozen_state;

// -----------------------------------------------------------------------
// C FFI entry points
// -----------------------------------------------------------------------

use std::path::Path;
use std::slice;

/// Train MCCFR and write the averaged strategy to `output_path`.
///
/// # Safety
///
/// All pointer arguments must be valid and point to properly sized data.
/// `output_path_ptr` must point to a valid UTF-8 null-terminated string.
/// `bet_fracs_ptr` must point to `n_bet_fracs` f64 values.
/// `assignments_ptr` must point to 169 i32 values.
#[no_mangle]
pub unsafe extern "C" fn rbm_train(
    // GameConfig fields
    small_blind: i32,
    big_blind: i32,
    starting_stack: i32,
    bet_fracs_ptr: *const f64,
    n_bet_fracs: u32,
    max_raises: u8,
    // TrainConfig fields
    iterations: u64,
    report_every: u64,
    n_buckets: u32,
    dcfr: bool,
    lcfr: bool,
    prune_threshold: f64,
    // Preflop assignments (169 values)
    assignments_ptr: *const i32,
    // Thread count (0 or 1 = single-threaded)
    num_threads: u32,
    // Output path (null-terminated UTF-8)
    output_path_ptr: *const u8,
    output_path_len: u32,
) -> i64 {
    // Build GameConfig
    let bet_fracs = slice::from_raw_parts(bet_fracs_ptr, n_bet_fracs as usize);
    let game_config = config::GameConfig {
        small_blind,
        big_blind,
        starting_stack,
        bet_fractions: bet_fracs.to_vec(),
        max_raises_per_round: max_raises,
    };

    // Build TrainConfig
    let train_config = config::TrainConfig {
        iterations,
        report_every,
        initial_size: 1_000_000,
        checkpoint_every: 0,
        prune_threshold,
        dcfr,
        lcfr,
        n_buckets,
        bucket_method: config::BucketMethod::default(),
        regret_scale_every: 1_000_000,
        freeze_after: 5_000_000,
    };

    // Preflop assignments
    let assignments_slice = slice::from_raw_parts(assignments_ptr, 169);
    let mut assignments = [0i32; 169];
    assignments.copy_from_slice(assignments_slice);

    // Output path
    let path_bytes = slice::from_raw_parts(output_path_ptr, output_path_len as usize);
    let output_path = match std::str::from_utf8(path_bytes) {
        Ok(s) => s,
        Err(_) => return -1,
    };

    // Train (returns CompactCfrState + PostflopState)
    let (states, _postflop) = if num_threads > 1 {
        train::train_mccfr_parallel(
            &game_config,
            &train_config,
            &assignments,
            num_threads as usize,
        )
    } else {
        train::train_mccfr(
            &game_config,
            &train_config,
            &assignments,
            None,
            None,
        )
    };

    // Save averaged strategy (compact version)
    match checkpoint::save_compact_averaged_strategy(Path::new(output_path), &states) {
        Ok(()) => {
            let total = states[0].len() + states[1].len();
            total as i64
        }
        Err(_) => -1,
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use rand::SeedableRng;
    use rand_xoshiro::Xoshiro256PlusPlus;

    #[test]
    fn test_info_key_matches_card_deal() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(123);
        let (p1, _p2, _board) = card::sample_deal(&mut rng);
        // Just verify it doesn't panic
        let buckets = [p1[0] as u32 % 10, 0, 0, 0];
        let key = info_key::make_info_key(&buckets, 0, b"cc");
        assert_ne!(key, 0);
    }

    #[test]
    fn test_cfr_roundtrip_compact() {
        let mut state = compact_state::CompactCfrState::new(100);
        let key = 42u64;
        let entry = state.find_or_add(key, 3);
        state.add_regret(&entry, 0, 10.0);
        state.add_regret(&entry, 1, -5.0);
        state.add_regret(&entry, 2, 3.0);

        let mut strat = [0.0f32; 3];
        let entry = *state.index.get(&key).unwrap();
        compact_state::regret_matching(&state, &entry, &mut strat);

        // Only positive regrets contribute
        assert!(strat[0] > 0.0);
        assert_eq!(strat[1], 0.0); // negative regret -> 0
        assert!(strat[2] > 0.0);
        assert!((strat.iter().sum::<f32>() - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_cfr_roundtrip_legacy() {
        // Keep testing legacy CfrState to ensure backward compat
        let mut state = cfr_state::CfrState::new(100);
        let key = 42u64;
        let entry = state.find_or_add(key, 3);
        entry.add_regret(0, 10.0);
        entry.add_regret(1, -5.0);
        entry.add_regret(2, 3.0);

        let mut strat = [0.0f32; 3];
        cfr_state::regret_matching(state.entries.get(&key).unwrap(), &mut strat);

        assert!(strat[0] > 0.0);
        assert_eq!(strat[1], 0.0);
        assert!(strat[2] > 0.0);
        assert!((strat.iter().sum::<f32>() - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_actions_config() {
        let config = config::GameConfig::slumbot();
        assert_eq!(config.small_blind, 50);
        assert_eq!(config.big_blind, 100);
        assert_eq!(config.bet_fractions.len(), 3);
    }

    #[test]
    fn test_full_pipeline_buckets_to_train() {
        // End-to-end: precompute buckets -> train -> averaged strategy
        let config = config::GameConfig::slumbot();
        let train_config = config::TrainConfig {
            iterations: 100,
            report_every: 0,
            initial_size: 1_000,
            checkpoint_every: 0,
            n_buckets: 20,
            ..Default::default()
        };
        let mut assignments = [0i32; 169];
        for (i, a) in assignments.iter_mut().enumerate() {
            *a = (i % 20) as i32;
        }

        let (states, _postflop) = train::train_mccfr(&config, &train_config, &assignments, None, None);

        // Verify averaged strategy sums to 1 for each info set (using compact_state)
        let avg = compact_state::average_strategy(&states[0]);
        for (_key, probs) in &avg {
            let sum: f32 = probs.iter().sum();
            assert!(
                (sum - 1.0).abs() < 0.01,
                "averaged strategy should sum to 1, got {}",
                sum,
            );
        }
    }
}
