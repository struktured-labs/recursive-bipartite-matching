/// Full MCCFR training loop.
///
/// Runs N iterations of external-sampling MCCFR, alternating the traverser
/// between P0 and P1 each iteration. Supports:
///   - DCFR discounting (lazy per-entry, applied on access)
///   - LCFR linear weighting
///   - Periodic progress reporting
///   - Periodic checkpointing
///   - Parallel training via rayon (independent thread-local states, merged)
///
/// Uses CompactCfrState (arena-backed i16 storage) for ~3x memory savings.

use std::path::Path;
use rand::SeedableRng;
use rand_xoshiro::Xoshiro256PlusPlus;

use crate::actions::{HistoryBuf, NlState};
use crate::buckets;
use crate::card;
use crate::cfr_state::DcfrTable;
use crate::compact_state::{self, CompactCfrState};
use crate::checkpoint;
use crate::config::{BucketMethod, GameConfig, TrainConfig};
use crate::rbm_buckets::{self, PostflopState};
use crate::rbm_distance::Config as RbmConfig;
use crate::traversal;

/// Merge src CompactCfrState into dst by summing all regret and strategy entries.
pub fn merge_cfr_state(dst: &mut CompactCfrState, src: &CompactCfrState) {
    compact_state::merge_compact_state(dst, src);
}

/// Run a single MCCFR iteration: sample a deal, compute buckets, traverse.
///
/// When `rbm_state` is provided, uses RBM-based post-flop bucketing.
/// Otherwise falls back to equity-based bucketing.
#[inline]
fn run_one_iteration(
    config: &GameConfig,
    train_config: &TrainConfig,
    preflop_assignments: &[i32; 169],
    cfr_states: &mut [CompactCfrState; 2],
    rng: &mut Xoshiro256PlusPlus,
    iteration: u64,
    dcfr_table: Option<&DcfrTable>,
    rbm_state: Option<(&RbmConfig, f64, &mut [PostflopState; 2])>,
) -> f64 {
    let (p1, p2, board) = card::sample_deal(rng);

    let (p1_buckets, p2_buckets) = match rbm_state {
        Some((rbm_config, epsilon, postflop_states)) => {
            let p1_b = rbm_buckets::precompute_buckets_rbm(
                &p1, &board, preflop_assignments, 0, epsilon, rbm_config,
                &mut postflop_states[0], rng,
            );
            let p2_b = rbm_buckets::precompute_buckets_rbm(
                &p2, &board, preflop_assignments, 1, epsilon, rbm_config,
                &mut postflop_states[1], rng,
            );
            (p1_b, p2_b)
        }
        None => {
            let p1_b = buckets::precompute_buckets(&p1, &board, train_config.n_buckets, preflop_assignments);
            let p2_b = buckets::precompute_buckets(&p2, &board, train_config.n_buckets, preflop_assignments);
            (p1_b, p2_b)
        }
    };

    let mut history = HistoryBuf::new();
    let state = NlState {
        to_act: 0,
        round_idx: 0,
        num_raises: 1, // Blinds count as a raise
        actions_remaining: 2,
        current_bet: config.big_blind,
        p_invested: [config.small_blind, config.big_blind],
        p_stack: [
            config.starting_stack - config.small_blind,
            config.starting_stack - config.big_blind,
        ],
        round_start_invested: [config.small_blind, config.big_blind],
    };

    let traverser = (iteration % 2) as u8;
    let lcfr_iter = if train_config.lcfr { iteration as u32 } else { 0 };
    let prune_threshold = train_config.prune_threshold as f32;
    // u16 epoch covers up to 65.5M iterations; beyond that DCFR discounting
    // effectively stops (discount factors are ~1.0 at that scale anyway).
    let dcfr_epoch = (iteration / 1000).min(65535) as u16;

    traversal::mccfr_traverse(
        config,
        &p1,
        &p2,
        &board,
        &p1_buckets,
        &p2_buckets,
        &mut history,
        state,
        traverser,
        cfr_states,
        rng,
        lcfr_iter,
        prune_threshold,
        dcfr_epoch,
        dcfr_table,
    )
}

/// Train MCCFR for the given number of iterations (single-threaded).
///
/// Returns (cfr_states, postflop_states) — the CFR state pair and the RBM
/// cluster state (needed for consistent bucketing during play).
pub fn train_mccfr(
    config: &GameConfig,
    train_config: &TrainConfig,
    preflop_assignments: &[i32; 169],
    resume_from: Option<(&[CompactCfrState; 2], u64)>,
    resume_postflop: Option<[PostflopState; 2]>,
) -> ([CompactCfrState; 2], [PostflopState; 2]) {
    let (mut cfr_states, start_iter) = match resume_from {
        Some((states, iter)) => {
            // Clone the states for resumed training
            let s0 = CompactCfrState {
                index: states[0].index.clone(),
                regret_arena: states[0].regret_arena.clone(),
                strategy_arena: states[0].strategy_arena.clone(),
                frozen: None, // Frozen state not cloneable; re-freeze after resume
            };
            let s1 = CompactCfrState {
                index: states[1].index.clone(),
                regret_arena: states[1].regret_arena.clone(),
                strategy_arena: states[1].strategy_arena.clone(),
                frozen: None,
            };
            ([s0, s1], iter)
        }
        None => {
            let s0 = CompactCfrState::new(train_config.initial_size);
            let s1 = CompactCfrState::new(train_config.initial_size);
            ([s0, s1], 0)
        }
    };

    let mut rng = Xoshiro256PlusPlus::seed_from_u64(start_iter ^ 0xDEAD_BEEF);
    let mut util_sum = 0.0f64;

    // Lazy DCFR: create table if DCFR is enabled
    let mut dcfr_table = if train_config.dcfr {
        Some(DcfrTable::new())
    } else {
        None
    };

    // RBM bucketing state: per-player PostflopState
    let (rbm_config, rbm_epsilon) = match &train_config.bucket_method {
        BucketMethod::Rbm { epsilon } => (Some(RbmConfig::default()), *epsilon),
        BucketMethod::Equity => (None, 0.0),
    };
    let mut postflop_states = resume_postflop.unwrap_or([PostflopState::new(), PostflopState::new()]);

    for iter in start_iter..train_config.iterations {
        // Ensure DCFR table covers current epoch
        let current_epoch = (iter / 1000) as u32;
        if let Some(ref mut dt) = dcfr_table {
            dt.ensure_epoch(current_epoch);
        }

        let rbm_arg = rbm_config.as_ref().map(|cfg| {
            (cfg, rbm_epsilon, &mut postflop_states)
        });

        let value = run_one_iteration(
            config,
            train_config,
            preflop_assignments,
            &mut cfr_states,
            &mut rng,
            iter,
            dcfr_table.as_ref(),
            rbm_arg,
        );
        util_sum += value;

        // Progress report
        if train_config.report_every > 0 && (iter + 1) % train_config.report_every == 0 {
            let avg_util = util_sum / (iter + 1 - start_iter) as f64;
            let rbm_clusters = if rbm_config.is_some() {
                format!(
                    "  rbm_clusters={}+{}",
                    postflop_states[0].total_clusters(),
                    postflop_states[1].total_clusters(),
                )
            } else {
                String::new()
            };
            eprintln!(
                "[iter {}] avg_util={:.2} P0={} P1={} info sets  regret={}+{} i16  strat={}+{} f32{}",
                iter + 1,
                avg_util,
                cfr_states[0].len(),
                cfr_states[1].len(),
                cfr_states[0].regret_arena.len(),
                cfr_states[1].regret_arena.len(),
                cfr_states[0].strategy_arena.len(),
                cfr_states[1].strategy_arena.len(),
                rbm_clusters,
            );
        }

        // Freeze / re-freeze: replace FxHashMap with MPHF periodically.
        // First freeze at freeze_after, then re-freeze every freeze_after
        // iterations to absorb overflow entries back into the MPHF.
        if train_config.freeze_after > 0
            && (iter + 1) % train_config.freeze_after == 0
        {
            cfr_states[0].freeze();
            cfr_states[1].freeze();
        }

        // Periodic regret scaling: halve all regrets to prevent i16 saturation
        if train_config.regret_scale_every > 0 && (iter + 1) % train_config.regret_scale_every == 0 {
            cfr_states[0].halve_regrets();
            cfr_states[1].halve_regrets();
            eprintln!("[iter {}] halved regrets (i16 saturation prevention)", iter + 1);
        }

        // Checkpoint
        if train_config.checkpoint_every > 0 && (iter + 1) % train_config.checkpoint_every == 0 {
            let ckpt_path = format!("checkpoint_{}.bin", iter + 1);
            if let Err(e) = checkpoint::save_compact_raw_states(
                Path::new(&ckpt_path),
                &cfr_states,
                iter + 1,
            ) {
                eprintln!("Warning: failed to save checkpoint: {}", e);
            } else {
                eprintln!("Checkpoint saved: {}", ckpt_path);
            }
            // Save PostflopState alongside for RBM resume
            if rbm_config.is_some() {
                let cluster_path = format!("checkpoint_{}.clusters", iter + 1);
                let f = std::fs::File::create(&cluster_path);
                if let Ok(f) = f {
                    let mut w = std::io::BufWriter::new(f);
                    for ps in postflop_states.iter() {
                        let _ = ps.save(&mut w);
                    }
                    eprintln!("Cluster state saved: {}", cluster_path);
                }
            }
        }
    }

    (cfr_states, postflop_states)
}

/// Train MCCFR in parallel using rayon.
///
/// Each thread gets its own CompactCfrState pair and RNG. After training, all
/// thread states are merged by summing regrets and strategy sums.
pub fn train_mccfr_parallel(
    config: &GameConfig,
    train_config: &TrainConfig,
    preflop_assignments: &[i32; 169],
    num_threads: usize,
) -> ([CompactCfrState; 2], [PostflopState; 2]) {
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(num_threads)
        .build()
        .expect("failed to build rayon thread pool");

    let iters_per_thread = train_config.iterations / num_threads as u64;
    let remainder = train_config.iterations % num_threads as u64;

    // Collect results from all threads
    let thread_results: Vec<[CompactCfrState; 2]> = pool.scope(|s| {
        let mut handles = Vec::with_capacity(num_threads);

        for thread_id in 0..num_threads {
            let config = config.clone();
            let mut thread_train_config = train_config.clone();

            // Distribute iterations evenly, with remainder going to first threads
            let my_iters = iters_per_thread + if (thread_id as u64) < remainder { 1 } else { 0 };
            thread_train_config.iterations = my_iters;

            // Suppress per-thread reporting to avoid interleaved output
            let original_report = thread_train_config.report_every;
            thread_train_config.checkpoint_every = 0; // No per-thread checkpoints

            let assignments = *preflop_assignments;
            let tid = thread_id;

            let (tx, rx) = std::sync::mpsc::channel();

            s.spawn(move |_| {
                let mut rng = Xoshiro256PlusPlus::seed_from_u64(
                    (tid as u64).wrapping_mul(0x9E3779B97F4A7C15) ^ 0xBEEF_CAFE,
                );

                let mut cfr_states = [
                    CompactCfrState::new(thread_train_config.initial_size / num_threads.max(1)),
                    CompactCfrState::new(thread_train_config.initial_size / num_threads.max(1)),
                ];

                let mut util_sum = 0.0f64;

                // Lazy DCFR table per thread
                let mut dcfr_table = if thread_train_config.dcfr {
                    Some(DcfrTable::new())
                } else {
                    None
                };

                // Per-thread RBM state (clusters don't merge across threads)
                let (rbm_config_t, rbm_epsilon_t) = match &thread_train_config.bucket_method {
                    BucketMethod::Rbm { epsilon } => (Some(RbmConfig::default()), *epsilon),
                    BucketMethod::Equity => (None, 0.0),
                };
                let mut postflop_states_t = [PostflopState::new(), PostflopState::new()];

                for iter in 0..my_iters {
                    let current_epoch = (iter / 1000) as u32;
                    if let Some(ref mut dt) = dcfr_table {
                        dt.ensure_epoch(current_epoch);
                    }

                    let rbm_arg = rbm_config_t.as_ref().map(|cfg| {
                        (cfg, rbm_epsilon_t, &mut postflop_states_t)
                    });

                    let value = run_one_iteration(
                        &config,
                        &thread_train_config,
                        &assignments,
                        &mut cfr_states,
                        &mut rng,
                        iter,
                        dcfr_table.as_ref(),
                        rbm_arg,
                    );
                    util_sum += value;

                    // Per-thread regret scaling
                    if thread_train_config.regret_scale_every > 0
                        && (iter + 1) % thread_train_config.regret_scale_every == 0
                    {
                        cfr_states[0].halve_regrets();
                        cfr_states[1].halve_regrets();
                    }

                    // Per-thread progress (only thread 0 reports)
                    if tid == 0 && original_report > 0 && (iter + 1) % original_report == 0 {
                        let avg_util = util_sum / (iter + 1) as f64;
                        eprintln!(
                            "[thread 0, iter {}] avg_util={:.2} P0={} P1={} info sets",
                            iter + 1,
                            avg_util,
                            cfr_states[0].len(),
                            cfr_states[1].len(),
                        );
                    }
                }

                tx.send(cfr_states).unwrap();
            });

            handles.push(rx);
        }

        handles.into_iter().map(|rx| rx.recv().unwrap()).collect()
    });

    // Merge all thread results
    let mut merged = [
        CompactCfrState::new(train_config.initial_size),
        CompactCfrState::new(train_config.initial_size),
    ];

    for thread_states in thread_results {
        for player in 0..2 {
            merge_cfr_state(&mut merged[player], &thread_states[player]);
        }
    }

    eprintln!(
        "Parallel training complete ({} threads): P0={} P1={} info sets",
        num_threads,
        merged[0].len(),
        merged[1].len(),
    );

    // Note: parallel training creates per-thread PostflopState that can't easily
    // be merged. Return empty states — caller should rebuild if needed.
    (merged, [PostflopState::new(), PostflopState::new()])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_assignments() -> [i32; 169] {
        let mut a = [0i32; 169];
        for (i, v) in a.iter_mut().enumerate() {
            *v = (i % 50) as i32;
        }
        a
    }

    #[test]
    fn test_merge_cfr_state() {
        let mut dst = CompactCfrState::new(100);
        let mut src = CompactCfrState::new(100);

        // Add entries to src
        {
            let e = src.find_or_add(42, 3);
            src.add_regret(&e, 0, 10.0);
            src.add_regret(&e, 1, 5.0);
            src.add_strategy(&e, 0, 100.0);
        }

        // Add overlapping entry to dst
        {
            let e = dst.find_or_add(42, 3);
            dst.add_regret(&e, 0, 20.0);
            dst.add_regret(&e, 1, -3.0);
            dst.add_strategy(&e, 0, 50.0);
        }

        // Add non-overlapping entry to src
        {
            let e = src.find_or_add(99, 2);
            src.add_regret(&e, 0, 7.0);
        }

        merge_cfr_state(&mut dst, &src);

        // Key 42 should be summed
        let e42 = *dst.index.get(&42).unwrap();
        assert!((dst.regret(&e42, 0) - 30.0).abs() < 1.0);
        assert!((dst.regret(&e42, 1) - 2.0).abs() < 1.0);
        assert!((dst.strategy(&e42, 0) - 150.0).abs() < 1.0);

        // Key 99 should be copied
        let e99 = *dst.index.get(&99).unwrap();
        assert!((dst.regret(&e99, 0) - 7.0).abs() < 1.0);
    }

    #[test]
    fn test_train_mccfr_small() {
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 500,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr(&config, &train_config, &assignments, None, None);

        assert!(states[0].len() > 0, "P0 should have info sets");
        assert!(states[1].len() > 0, "P1 should have info sets");
        eprintln!("500 iters: P0={} P1={} info sets", states[0].len(), states[1].len());
    }

    #[test]
    fn test_train_mccfr_dcfr() {
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 2000,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: true,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr(&config, &train_config, &assignments, None, None);
        assert!(states[0].len() > 0);
    }

    #[test]
    fn test_train_mccfr_lcfr() {
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 500,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: true,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr(&config, &train_config, &assignments, None, None);
        assert!(states[0].len() > 0);
    }

    #[test]
    fn test_train_parallel_small() {
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 400,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr_parallel(&config, &train_config, &assignments, 2);

        assert!(states[0].len() > 0, "P0 should have info sets after parallel training");
        assert!(states[1].len() > 0, "P1 should have info sets after parallel training");
        eprintln!(
            "Parallel 400 iters (2 threads): P0={} P1={} info sets",
            states[0].len(),
            states[1].len(),
        );
    }

    #[test]
    fn test_train_checkpoint_roundtrip() {
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 200,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
        };
        let assignments = default_assignments();

        // Train phase 1
        let (states, _) = train_mccfr(&config, &train_config, &assignments, None, None);
        let p0_len = states[0].len();
        let p1_len = states[1].len();

        // Save and reload
        let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tmp");
        std::fs::create_dir_all(&dir).ok();
        let path = dir.join("test_train_ckpt_compact.bin");

        checkpoint::save_compact_raw_states(&path, &states, 200).unwrap();
        let (loaded, iter) = checkpoint::load_compact_raw_states(&path).unwrap();

        assert_eq!(iter, 200);
        assert_eq!(loaded[0].len(), p0_len);
        assert_eq!(loaded[1].len(), p1_len);

        // Resume training
        let train_config2 = TrainConfig {
            iterations: 400,
            ..train_config
        };
        let (resumed, _) = train_mccfr(&config, &train_config2, &assignments, Some((&loaded, 200)), None);

        // Should have at least as many info sets as before
        assert!(resumed[0].len() >= p0_len);
        assert!(resumed[1].len() >= p1_len);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_train_dcfr_lcfr_combined() {
        // Test DCFR + LCFR combined to verify they work together
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 2000,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: true,
            lcfr: true,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr(&config, &train_config, &assignments, None, None);
        assert!(states[0].len() > 0);
        assert!(states[1].len() > 0);
    }
}
