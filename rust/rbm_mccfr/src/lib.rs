//! RBM-MCCFR: High-performance MCCFR training engine for No-Limit Hold'em.
//!
//! This crate implements the performance-critical hot loop of Monte Carlo
//! Counterfactual Regret Minimization. It's designed to be called from OCaml
//! via C FFI, with OCaml handling the high-level orchestration (RBM distance,
//! clustering, Slumbot API) and Rust handling the tight inner loop.

pub mod card;
pub mod config;
pub mod info_key;
pub mod cfr_state;
pub mod actions;

pub mod hand_eval;
pub mod traversal;

// Phase 2 (TODO):
// pub mod buckets;      // Equity-based bucket computation
// pub mod checkpoint;   // RBMCFR02 format read/write

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
    fn test_cfr_roundtrip() {
        let mut state = cfr_state::CfrState::new(100);
        let key = 42u64;
        let entry = state.find_or_add(key, 3);
        entry.add_regret(0, 10.0);
        entry.add_regret(1, -5.0);
        entry.add_regret(2, 3.0);

        let mut strat = [0.0f32; 3];
        cfr_state::regret_matching(state.entries.get(&key).unwrap(), &mut strat);

        // Only positive regrets contribute
        assert!(strat[0] > 0.0);
        assert_eq!(strat[1], 0.0); // negative regret → 0
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
}
