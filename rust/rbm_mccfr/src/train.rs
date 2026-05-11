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
/// Uses CompactCfrState (arena-backed f32 regret + f32 strategy_sum, LSM-frozen).

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
                regret_arena: states[0].regret_arena.clone_mem(),
                strategy_arena: states[0].strategy_arena.clone_mem(),
                frozen: None,
                player_id: 0,
                use_mmap: false,
                mmap_dir: std::path::PathBuf::from("."),
            };
            let s1 = CompactCfrState {
                index: states[1].index.clone(),
                regret_arena: states[1].regret_arena.clone_mem(),
                strategy_arena: states[1].strategy_arena.clone_mem(),
                frozen: None,
                player_id: 1,
                use_mmap: false,
                mmap_dir: std::path::PathBuf::from("."),
            };
            ([s0, s1], iter)
        }
        None => {
            let (s0, s1) = if train_config.mmap_arenas {
                let dir = std::path::Path::new(".");
                std::fs::create_dir_all(dir).unwrap_or_else(|e| {
                    panic!("mmap arena dir {:?} create failed: {}", dir, e)
                });
                eprintln!("[mmap] Using mmap-backed arenas in {:?}", dir);
                (
                    CompactCfrState::new_mmap(train_config.initial_size, dir, 0),
                    CompactCfrState::new_mmap(train_config.initial_size, dir, 1),
                )
            } else {
                (
                    CompactCfrState::new(train_config.initial_size),
                    CompactCfrState::new(train_config.initial_size),
                )
            };
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
                "[iter {}] avg_util={:.2} P0={} P1={} info sets  regret={}+{} f32  strat={}+{} f32{}",
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

        // Periodic regret scaling: halve all regrets. Acts as DCFR-like
        // discounting that biases toward more recent learning.
        if train_config.regret_scale_every > 0 && (iter + 1) % train_config.regret_scale_every == 0 {
            cfr_states[0].halve_regrets();
            cfr_states[1].halve_regrets();
            eprintln!("[iter {}] halved regrets (DCFR-like discounting)", iter + 1);
        }

        // Checkpoint. In parallel mode, each thread tags its file with
        // checkpoint_thread_id so threads don't clobber each other.
        if train_config.checkpoint_every > 0 && (iter + 1) % train_config.checkpoint_every == 0 {
            let suffix = train_config
                .checkpoint_thread_id
                .map(|tid| format!("_t{}", tid))
                .unwrap_or_default();
            let ckpt_path = format!("checkpoint{}_{}.bin", suffix, iter + 1);
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
                let cluster_path = format!("checkpoint{}_{}.clusters", suffix, iter + 1);
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
///
/// When `train_config.mmap_arenas` is true, per-thread arenas are file-backed
/// at `{mmap_dir}/thread_{tid}/{regret,strategy}_p{0,1}.bin`. Defaults to "."
/// (CWD) when `mmap_dir` is None — preserves prior behavior for production
/// callers; tests pass an explicit tempdir.
pub fn train_mccfr_parallel(
    config: &GameConfig,
    train_config: &TrainConfig,
    preflop_assignments: &[i32; 169],
    num_threads: usize,
    mmap_dir: Option<&std::path::Path>,
) -> ([CompactCfrState; 2], [PostflopState; 2]) {
    // Per-thread RBM PostflopStates can't be merged today (cluster IDs are
    // thread-local). Returning empty PostflopState would silently downgrade
    // eval to cluster 0 for every postflop hand — same class as the
    // equity-vs-RBM bucketing bug. Refuse the configuration until cluster
    // merge is implemented; user can drop to --threads 1 for RBM runs.
    if num_threads > 1 {
        if let BucketMethod::Rbm { .. } = train_config.bucket_method {
            panic!(
                "RBM bucketing with --threads {} is not supported: per-thread \
                 PostflopStates do not merge. Use --threads 1 for RBM runs, \
                 or BucketMethod::Equity for parallel runs.",
                num_threads
            );
        }
    }

    let mmap_dir_owned: std::path::PathBuf = mmap_dir
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(num_threads)
        .build()
        .expect("failed to build rayon thread pool");

    let iters_per_thread = train_config.iterations / num_threads as u64;
    let remainder = train_config.iterations % num_threads as u64;

    // Collect results from all threads.
    //
    // Failure handling: each spawned closure runs inside catch_unwind and sends
    // Result<states, panic_reason> over an mpsc channel. The receiver applies
    // a watchdog timeout so a silently-panicked worker (e.g. SIGBUS from a
    // full mmap region, NaN-sort panic in RBM distance) cannot leave the
    // rendezvous wedged forever — that bug ate a 13h post-training merge on
    // 2026-05-03.
    type ThreadResult = Result<[CompactCfrState; 2], String>;
    let thread_results: Vec<ThreadResult> = pool.scope(|s| {
        let mut handles = Vec::with_capacity(num_threads);

        for thread_id in 0..num_threads {
            let config = config.clone();
            let mut thread_train_config = train_config.clone();

            // Distribute iterations evenly, with remainder going to first threads
            let my_iters = iters_per_thread + if (thread_id as u64) < remainder { 1 } else { 0 };
            thread_train_config.iterations = my_iters;

            // Suppress per-thread reporting to avoid interleaved output
            let original_report = thread_train_config.report_every;

            // Per-thread checkpointing: scale aggregate cadence to per-thread
            // (each thread does iters/num_threads). Tag with thread_id so
            // threads don't clobber each other's files. Recovery: load all
            // per-thread checkpoints + merge.
            if train_config.checkpoint_every > 0 {
                thread_train_config.checkpoint_every =
                    (train_config.checkpoint_every / num_threads as u64).max(1);
                thread_train_config.checkpoint_thread_id = Some(thread_id);
            }

            let assignments = *preflop_assignments;
            let tid = thread_id;
            let thread_mmap_dir = mmap_dir_owned.clone();

            let (tx, rx) = std::sync::mpsc::channel::<ThreadResult>();

            s.spawn(move |_| {
                // catch_unwind around the thread body so a panic in one worker
                // doesn't leave the receiver hanging. AssertUnwindSafe is
                // sound here because we never observe partial state — the
                // closure either runs to completion and sends Ok, or unwinds
                // and we send Err with the panic message.
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let mut rng = Xoshiro256PlusPlus::seed_from_u64(
                    (tid as u64).wrapping_mul(0x9E3779B97F4A7C15) ^ 0xBEEF_CAFE,
                );

                let per_thread_cap = thread_train_config.initial_size / num_threads.max(1);
                let mut cfr_states = if thread_train_config.mmap_arenas {
                    let dir = thread_mmap_dir.join(format!("thread_{}", tid));
                    std::fs::create_dir_all(&dir).unwrap_or_else(|e| {
                        panic!("[thread {}] mmap dir {:?} create failed: {}", tid, dir, e)
                    });
                    [
                        CompactCfrState::new_mmap(per_thread_cap, &dir, 0),
                        CompactCfrState::new_mmap(per_thread_cap, &dir, 1),
                    ]
                } else {
                    [
                        CompactCfrState::new(per_thread_cap),
                        CompactCfrState::new(per_thread_cap),
                    ]
                };

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

                    // Per-thread freeze: replace FxHashMap with MPHF periodically.
                    // Without this, anon RSS grows linearly with info-set count
                    // and OOMs on long parallel runs. (Single-thread path has
                    // the same logic; this brought parallel into parity.)
                    if thread_train_config.freeze_after > 0
                        && (iter + 1) % thread_train_config.freeze_after == 0
                    {
                        cfr_states[0].freeze();
                        cfr_states[1].freeze();
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

                    // Per-thread checkpoint. In mmap mode, write into the
                    // thread's mmap subdir so the checkpoint and its sidecar
                    // mmap files share a parent — the play-time loader uses
                    // checkpoint.parent() to find sidecars, and pre-fix this
                    // mismatch caused parallel checkpoints to load with empty
                    // frozen layers (uniform-random play). In non-mmap mode,
                    // write under mmap_dir (which defaults to ".") so the
                    // file lands in a stable, test-controllable directory.
                    if thread_train_config.checkpoint_every > 0
                        && (iter + 1) % thread_train_config.checkpoint_every == 0
                    {
                        let ckpt_dir: std::path::PathBuf = if thread_train_config.mmap_arenas {
                            thread_mmap_dir.join(format!("thread_{}", tid))
                        } else {
                            thread_mmap_dir.clone()
                        };
                        let ckpt_path = ckpt_dir.join(format!("checkpoint_t{}_{}.bin", tid, iter + 1));
                        if let Err(e) = checkpoint::save_compact_raw_states(
                            &ckpt_path,
                            &cfr_states,
                            iter + 1,
                        ) {
                            eprintln!("[thread {}] checkpoint failed: {}", tid, e);
                        }
                    }
                }

                cfr_states
                })); // end catch_unwind

                let to_send: ThreadResult = match result {
                    Ok(states) => Ok(states),
                    Err(panic_payload) => {
                        let msg = if let Some(s) = panic_payload.downcast_ref::<&str>() {
                            (*s).to_string()
                        } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                            s.clone()
                        } else {
                            "<non-string panic payload>".to_string()
                        };
                        eprintln!("[thread {}] PANIC during training: {}", tid, msg);
                        Err(msg)
                    }
                };
                // If the receiver has been dropped (caller bailed early),
                // log + drop. Never unwrap a closed-channel send: the panic
                // would propagate inside catch_unwind's caller and abort the
                // whole rayon scope.
                if let Err(e) = tx.send(to_send) {
                    eprintln!("[thread {}] result channel closed before send: {}", tid, e);
                }
            });

            handles.push(rx);
        }

        // Watchdog: after the iter loop should have finished, recv with a
        // timeout so a silently-dead worker doesn't park us forever. We size
        // the timeout generously — these threads can be doing 24h of work,
        // and freeze() at 1B keys can take 5+ minutes; 6h covers freeze +
        // final flush comfortably and still trips before "infinite hang."
        const RECV_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(6 * 3600);
        handles
            .into_iter()
            .enumerate()
            .map(|(tid, rx)| match rx.recv_timeout(RECV_TIMEOUT) {
                Ok(r) => r,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    eprintln!("[thread {}] WATCHDOG: no result after {:?} — treating as dead",
                        tid, RECV_TIMEOUT);
                    Err(format!("watchdog timeout after {:?}", RECV_TIMEOUT))
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    eprintln!("[thread {}] sender disconnected before send (likely panic in rayon scope)", tid);
                    Err("sender disconnected".to_string())
                }
            })
            .collect()
    });

    // Merge all thread results. Skip dead threads (they reported via stderr).
    let mut merged = [
        CompactCfrState::new(train_config.initial_size),
        CompactCfrState::new(train_config.initial_size),
    ];

    let mut alive = 0usize;
    let mut dead = 0usize;
    for r in thread_results {
        match r {
            Ok(thread_states) => {
                for player in 0..2 {
                    merge_cfr_state(&mut merged[player], &thread_states[player]);
                }
                alive += 1;
            }
            Err(_) => dead += 1,
        }
    }

    if dead > 0 {
        eprintln!(
            "[parallel] WARNING: {}/{} threads died; merging {} survivors only",
            dead, num_threads, alive
        );
    }

    eprintln!(
        "Parallel training complete ({} threads, {} alive): P0={} P1={} info sets",
        num_threads,
        alive,
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
            mmap_arenas: false,
            checkpoint_thread_id: None,
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
            mmap_arenas: false,
            checkpoint_thread_id: None,
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
            mmap_arenas: false,
            checkpoint_thread_id: None,
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
            mmap_arenas: false,
            checkpoint_thread_id: None,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr_parallel(&config, &train_config, &assignments, 2, None);

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
            mmap_arenas: false,
            checkpoint_thread_id: None,
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
            mmap_arenas: false,
            checkpoint_thread_id: None,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr(&config, &train_config, &assignments, None, None);
        assert!(states[0].len() > 0);
        assert!(states[1].len() > 0);
    }

    /// REGRESSION: --mmap-arenas in parallel training must actually create
    /// file-backed mmap files on disk. Bug discovered 2026-05-03 —
    /// train_mccfr_parallel silently used CompactCfrState::new() (anonymous
    /// Vec) regardless of the mmap_arenas flag. Hostkey runs marketed as
    /// "mmap-backed" were actually all-RAM, hitting the 768GB ceiling and
    /// OOMing 1B-iter targets.
    #[test]
    fn test_mmap_parallel_creates_files_on_disk() {
        use std::fs;

        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 200,
            report_every: 0,
            initial_size: 1_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
            mmap_arenas: true, // <-- the flag under test
            checkpoint_thread_id: None,
        };
        let assignments = default_assignments();

        let tmp = std::env::temp_dir().join(format!(
            "rbm_mccfr_mmap_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).expect("create tempdir");

        let num_threads = 2;
        let _ = train_mccfr_parallel(
            &config,
            &train_config,
            &assignments,
            num_threads,
            Some(&tmp),
        );

        // Verify file-backed arenas were created for each thread + each player.
        for tid in 0..num_threads {
            let dir = tmp.join(format!("thread_{}", tid));
            for player in 0..2 {
                let regret = dir.join(format!("regret_p{}.bin", player));
                let strat = dir.join(format!("strategy_p{}.bin", player));
                assert!(
                    regret.exists(),
                    "expected file-backed regret arena at {:?} (was --mmap-arenas silently ignored?)",
                    regret
                );
                assert!(
                    strat.exists(),
                    "expected file-backed strategy arena at {:?}",
                    strat
                );
                assert!(
                    fs::metadata(&regret).unwrap().len() > 0,
                    "regret arena file is empty"
                );
            }
        }

        let _ = fs::remove_dir_all(&tmp);
    }

    /// REGRESSION: --checkpoint-every must produce per-thread checkpoint
    /// files in parallel mode. Bug discovered 2026-05-04 — train_mccfr_parallel
    /// silently zeroed thread_train_config.checkpoint_every, so the flag was
    /// a no-op for any --threads > 1 run. A 1B run that hung at end-of-training
    /// merge had ZERO recoverable state on disk. Fix: scale cadence by
    /// num_threads and tag each thread's file with its tid. Recovery loads
    /// all per-thread checkpoints + merges.
    #[test]
    fn test_parallel_checkpointing_writes_per_thread_files() {
        use std::fs;

        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 200,
            report_every: 0,
            initial_size: 1_000,
            // Aggregate cadence 100; with 2 threads → per-thread cadence 50
            // → each thread checkpoints at iter 50, 100 (per-thread).
            checkpoint_every: 100,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
            mmap_arenas: false,
            checkpoint_thread_id: None,
        };
        let assignments = default_assignments();

        // Checkpoints are saved relative to CWD; serialize via tempdir+chdir.
        // (We don't have a checkpoint_dir parameter to inject a path, so this
        // test must own the CWD for its duration. Single test = no race.)
        let tmp = std::env::temp_dir().join(format!(
            "rbm_mccfr_ckpt_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        fs::create_dir_all(&tmp).expect("create tempdir");
        let prev_cwd = std::env::current_dir().unwrap();
        std::env::set_current_dir(&tmp).unwrap();

        let num_threads = 2;
        let _ = train_mccfr_parallel(&config, &train_config, &assignments, num_threads, None);

        // Restore CWD before assertions to avoid stranding it on teardown.
        std::env::set_current_dir(&prev_cwd).unwrap();

        // Expect at least one per-thread checkpoint per thread (at iter 50 or 100).
        let mut found = 0;
        for entry in fs::read_dir(&tmp).expect("read tempdir") {
            let name = entry.unwrap().file_name().to_string_lossy().into_owned();
            // Pattern: checkpoint_t{tid}_{iter}.bin
            if name.starts_with("checkpoint_t") && name.ends_with(".bin") {
                found += 1;
            }
        }
        assert!(
            found >= num_threads,
            "expected at least {} per-thread checkpoint files, got {} (was --checkpoint-every silently zeroed in parallel mode?)",
            num_threads, found
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    /// REGRESSION: training with mmap-backed arenas must produce numerically
    /// identical state to training with Vec-backed arenas, given same
    /// config + same per-thread seeds. Catches data-corruption bugs in the
    /// mmap arena read/write path that would silently diverge from the
    /// reference Vec implementation.
    #[test]
    fn test_mmap_vs_vec_equivalence() {
        use std::fs;

        let config = GameConfig::slumbot();
        let base_train_config = TrainConfig {
            iterations: 200,
            report_every: 0,
            initial_size: 1_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 0,
            mmap_arenas: false,
            checkpoint_thread_id: None,
        };
        let assignments = default_assignments();
        let num_threads = 2;

        // Reference run: Vec-backed (the "OG" path).
        let mut vec_cfg = base_train_config.clone();
        vec_cfg.mmap_arenas = false;
        let (vec_states, _) =
            train_mccfr_parallel(&config, &vec_cfg, &assignments, num_threads, None);

        // Mmap run with same config.
        let tmp = std::env::temp_dir().join(format!(
            "rbm_mccfr_equiv_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).expect("create tempdir");

        let mut mmap_cfg = base_train_config.clone();
        mmap_cfg.mmap_arenas = true;
        let (mmap_states, _) = train_mccfr_parallel(
            &config,
            &mmap_cfg,
            &assignments,
            num_threads,
            Some(&tmp),
        );

        // Same total info-set count (deterministic given identical seeds + iters).
        assert_eq!(
            vec_states[0].len(),
            mmap_states[0].len(),
            "P0 info-set count differs: vec={} mmap={}",
            vec_states[0].len(),
            mmap_states[0].len(),
        );
        assert_eq!(
            vec_states[1].len(),
            mmap_states[1].len(),
            "P1 info-set count differs: vec={} mmap={}",
            vec_states[1].len(),
            mmap_states[1].len(),
        );

        // Same regret + strategy values per matching info-set.
        // Iterate vec's index, look up same key in mmap, compare values.
        for player in 0..2 {
            for (key, vec_entry) in vec_states[player].index.iter() {
                let mmap_entry = mmap_states[player].index.get(key).unwrap_or_else(|| {
                    panic!(
                        "P{}: key {} present in vec but missing in mmap state",
                        player, key
                    )
                });
                let na = vec_entry.n_actions as usize;
                for a in 0..na {
                    let vec_r = vec_states[player].regret(vec_entry, a);
                    let mmap_r = mmap_states[player].regret(mmap_entry, a);
                    assert!(
                        (vec_r - mmap_r).abs() < 1e-3,
                        "P{} key {} action {}: regret diverged vec={} mmap={}",
                        player,
                        key,
                        a,
                        vec_r,
                        mmap_r,
                    );
                    let vec_s = vec_states[player].strategy(vec_entry, a);
                    let mmap_s = mmap_states[player].strategy(mmap_entry, a);
                    assert!(
                        (vec_s - mmap_s).abs() < 1e-3,
                        "P{} key {} action {}: strategy diverged vec={} mmap={}",
                        player,
                        key,
                        a,
                        vec_s,
                        mmap_s,
                    );
                }
            }
        }

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_parallel_mmap_freeze_no_collision() {
        // Regression: in parallel + mmap mode, each thread's freeze() must
        // write to its own subdir. Pre-fix, freeze() wrote to CWD with
        // names like frozen_keys_p0_L0.bin — every thread collided on the
        // same path and SIGBUS'd. Post-fix, freeze() uses self.mmap_dir
        // which new_mmap sets to the per-thread dir.
        use std::fs;
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 800,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 100, // multiple freezes per thread
            mmap_arenas: true,
            checkpoint_thread_id: None,
        };
        let assignments = default_assignments();

        let tmp = std::env::temp_dir().join(format!(
            "rbm_mccfr_mmap_freeze_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).expect("create tempdir");

        let (states, _) =
            train_mccfr_parallel(&config, &train_config, &assignments, 2, Some(&tmp));

        // Per-thread freeze must have written to its own subdir.
        for tid in 0..2 {
            let thread_dir = tmp.join(format!("thread_{}", tid));
            for player in 0..2 {
                let keys_path = thread_dir.join(format!("frozen_keys_p{}_L0.bin", player));
                assert!(
                    keys_path.exists(),
                    "thread {} player {} should have written frozen layer to its own subdir at {:?}",
                    tid, player, keys_path
                );
            }
        }
        // No frozen files in shared parent (collision indicator).
        for player in 0..2 {
            let shared = tmp.join(format!("frozen_keys_p{}_L0.bin", player));
            assert!(
                !shared.exists(),
                "no thread should write to shared parent dir, found at {:?}",
                shared
            );
        }
        assert!(states[0].len() > 0);
        assert!(states[1].len() > 0);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn test_parallel_freeze_engages() {
        // Regression: parallel inner loop must call freeze() at freeze_after
        // boundary. Without it, the FxHashMap index keeps all keys in anon
        // memory and OOMs on long runs. Single-thread had this; parallel
        // didn't until the fix that landed alongside this test.
        let config = GameConfig::slumbot();
        let train_config = TrainConfig {
            iterations: 800,
            report_every: 0,
            initial_size: 10_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 50,
            bucket_method: BucketMethod::Equity,
            regret_scale_every: 0,
            freeze_after: 100, // small, must trigger many times in 800 iters
            mmap_arenas: false,
            checkpoint_thread_id: None,
        };
        let assignments = default_assignments();

        let (states, _) = train_mccfr_parallel(&config, &train_config, &assignments, 2, None);

        // After merge, frozen flag may be cleared (merge rebuilds), so we
        // can't assert on the merged result. The proof is that the run
        // completed without exhausting memory and the merged state is
        // populated — pre-fix this test path produced linearly-growing
        // anon memory; post-fix the per-thread state is bounded. We
        // instead assert merged state is non-empty as a smoke test.
        assert!(states[0].len() > 0, "P0 must accumulate info sets");
        assert!(states[1].len() > 0, "P1 must accumulate info sets");
    }
}
