//! Standalone MCCFR training binary with optional Slumbot play.
//!
//! Uses CompactCfrState (arena-backed i16 storage) for ~3x memory savings.
//!
//! Usage:
//!   rbm-mccfr [options]
//!
//! Options:
//!   --iterations N       Number of MCCFR iterations (default: 1000000)
//!   --threads N          Number of threads (default: 1, 0 = auto)
//!   --n-buckets N        Bucket count per street (default: 169)
//!   --dcfr               Enable DCFR discounting
//!   --lcfr               Enable LCFR linear weighting
//!   --output PATH        Output strategy file (default: strategy_rust.bin)
//!   --report-every N     Report progress every N iters (default: 10000)
//!   --checkpoint-every N Save checkpoint every N iters (default: 0 = off)
//!   --resume PATH        Resume from a raw checkpoint file
//!   --play N             Play N hands against Slumbot after training
//!   --play-only N        Play N hands against Slumbot (no training, requires --strategy)
//!   --strategy PATH      Load strategy from file (for --play-only)
//!   --verbose            Verbose output during play
//!   --bucket-method M    Bucketing method: "rbm" (default) or "equity"
//!   --rbm-epsilon F      RBM cluster epsilon (default: 0.5)

use std::path::Path;
use std::time::Instant;

use rbm_mccfr::checkpoint;
use rbm_mccfr::config::{BucketMethod, GameConfig, TrainConfig};
use rbm_mccfr::slumbot;
use rbm_mccfr::train;

struct CliArgs {
    game_config: GameConfig,
    train_config: TrainConfig,
    assignments: [i32; 169],
    num_threads: usize,
    output: String,
    resume_path: Option<String>,
    play_hands: u32,
    play_only_hands: u32,
    strategy_path: Option<String>,
    verbose: bool,
}

fn parse_args() -> CliArgs {
    let args: Vec<String> = std::env::args().collect();
    let mut game_config = GameConfig::slumbot();
    let mut train_config = TrainConfig::default();
    let mut num_threads = 1usize;
    let mut output = "strategy_rust.bin".to_string();
    let mut resume_path: Option<String> = None;
    let mut play_hands = 0u32;
    let mut play_only_hands = 0u32;
    let mut strategy_path: Option<String> = None;
    let mut verbose = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--iterations" => {
                i += 1;
                train_config.iterations = args[i].parse().expect("bad --iterations");
            }
            "--threads" => {
                i += 1;
                num_threads = args[i].parse().expect("bad --threads");
                if num_threads == 0 {
                    num_threads = num_cpus();
                }
            }
            "--n-buckets" => {
                i += 1;
                train_config.n_buckets = args[i].parse().expect("bad --n-buckets");
            }
            "--dcfr" => {
                train_config.dcfr = true;
            }
            "--lcfr" => {
                train_config.lcfr = true;
            }
            "--output" => {
                i += 1;
                output = args[i].clone();
            }
            "--report-every" => {
                i += 1;
                train_config.report_every = args[i].parse().expect("bad --report-every");
            }
            "--checkpoint-every" => {
                i += 1;
                train_config.checkpoint_every = args[i].parse().expect("bad --checkpoint-every");
            }
            "--resume" => {
                i += 1;
                resume_path = Some(args[i].clone());
            }
            "--small-blind" => {
                i += 1;
                game_config.small_blind = args[i].parse().expect("bad --small-blind");
            }
            "--big-blind" => {
                i += 1;
                game_config.big_blind = args[i].parse().expect("bad --big-blind");
            }
            "--starting-stack" => {
                i += 1;
                game_config.starting_stack = args[i].parse().expect("bad --starting-stack");
            }
            "--max-raises" => {
                i += 1;
                game_config.max_raises_per_round = args[i].parse().expect("bad --max-raises");
            }
            "--prune-threshold" => {
                i += 1;
                train_config.prune_threshold = args[i].parse().expect("bad --prune-threshold");
            }
            "--play" => {
                i += 1;
                play_hands = args[i].parse().expect("bad --play");
            }
            "--play-only" => {
                i += 1;
                play_only_hands = args[i].parse().expect("bad --play-only");
            }
            "--strategy" => {
                i += 1;
                strategy_path = Some(args[i].clone());
            }
            "--verbose" => {
                verbose = true;
            }
            "--bucket-method" => {
                i += 1;
                match args[i].as_str() {
                    "rbm" => {
                        // Keep existing epsilon or set default
                        if let BucketMethod::Rbm { .. } = train_config.bucket_method {
                            // already RBM, keep epsilon
                        } else {
                            train_config.bucket_method = BucketMethod::Rbm { epsilon: 0.5 };
                        }
                    }
                    "equity" => {
                        train_config.bucket_method = BucketMethod::Equity;
                    }
                    other => {
                        eprintln!("Unknown bucket method '{}'. Use 'rbm' or 'equity'.", other);
                        std::process::exit(1);
                    }
                }
            }
            "--rbm-epsilon" => {
                i += 1;
                let eps: f64 = args[i].parse().expect("bad --rbm-epsilon");
                train_config.bucket_method = BucketMethod::Rbm { epsilon: eps };
            }
            "--regret-scale-every" => {
                i += 1;
                train_config.regret_scale_every = args[i].parse().expect("bad --regret-scale-every");
            }
            "--freeze-after" => {
                i += 1;
                train_config.freeze_after = args[i].parse().expect("bad --freeze-after");
            }
            "--no-freeze" => {
                train_config.freeze_after = 0;
            }
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            other => {
                eprintln!("Unknown argument: {}", other);
                print_help();
                std::process::exit(1);
            }
        }
        i += 1;
    }

    // Default preflop assignments: uniform quantile bucketing (0..n_buckets)
    let n = train_config.n_buckets;
    let mut assignments = [0i32; 169];
    for (idx, a) in assignments.iter_mut().enumerate() {
        *a = ((idx as u32 * n) / 169).min(n - 1) as i32;
    }

    CliArgs {
        game_config,
        train_config,
        assignments,
        num_threads,
        output,
        resume_path,
        play_hands,
        play_only_hands,
        strategy_path,
        verbose,
    }
}

fn print_help() {
    eprintln!("rbm-mccfr: High-performance MCCFR training for No-Limit Hold'em");
    eprintln!("           (compact i16 arena storage — ~3x less memory)");
    eprintln!();
    eprintln!("Training options:");
    eprintln!("  --iterations N       Number of MCCFR iterations (default: 1000000)");
    eprintln!("  --threads N          Number of threads (default: 1, 0 = auto-detect)");
    eprintln!("  --n-buckets N        Bucket count per street (default: 169)");
    eprintln!("  --dcfr               Enable DCFR discounting");
    eprintln!("  --lcfr               Enable LCFR linear weighting");
    eprintln!("  --output PATH        Output strategy file (default: strategy_rust.bin)");
    eprintln!("  --report-every N     Report every N iters (default: 10000)");
    eprintln!("  --checkpoint-every N Checkpoint every N iters (default: 0 = off)");
    eprintln!("  --resume PATH        Resume from raw checkpoint (supports legacy + compact)");
    eprintln!("  --small-blind N      Small blind size (default: 50)");
    eprintln!("  --big-blind N        Big blind size (default: 100)");
    eprintln!("  --starting-stack N   Starting stack (default: 20000)");
    eprintln!("  --max-raises N       Max raises per round (default: 4)");
    eprintln!("  --prune-threshold F  Prune threshold (default: -3e8)");
    eprintln!("  --bucket-method M    Bucketing method: 'rbm' (default) or 'equity'");
    eprintln!("  --rbm-epsilon F      RBM cluster epsilon (default: 0.5)");
    eprintln!("  --regret-scale-every N  Halve regrets every N iters to prevent i16 saturation (default: 1000000, 0 = off)");
    eprintln!();
    eprintln!("Slumbot play options:");
    eprintln!("  --play N             Play N hands against Slumbot after training");
    eprintln!("  --play-only N        Play N hands (no training, requires --strategy)");
    eprintln!("  --strategy PATH      Load strategy from file (for --play-only)");
    eprintln!("  --verbose            Verbose output during play");
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

/// Play against Slumbot using a loaded strategy file.
/// Auto-detects format: RBMCMP01 (compact, ~32GB) or RBMRUST1 (full, ~119GB).
fn play_against_slumbot(
    strategy_path: &str,
    num_hands: u32,
    n_buckets: u32,
    assignments: &[i32; 169],
    game_config: &GameConfig,
    bucket_method: &BucketMethod,
    verbose: bool,
) {
    eprintln!();
    eprintln!("=== Slumbot Play ===");
    eprintln!("Loading strategy from: {}", strategy_path);

    let play_strategy = slumbot::load_play_strategy(Path::new(strategy_path))
        .expect("failed to load strategy");

    eprintln!("Loaded P0={} P1={} info sets", play_strategy.len(0), play_strategy.len(1));
    eprintln!("Playing {} hands against Slumbot...", num_hands);

    let mut play_config = slumbot::PlayConfig::default();
    play_config.n_buckets = n_buckets;
    play_config.preflop_assignments = *assignments;
    play_config.game_config = game_config.clone();
    play_config.bucket_method = bucket_method.clone();
    play_config.verbose = verbose;

    match slumbot::run_session(&play_strategy, &mut play_config, num_hands) {
        Ok(result) => {
            eprintln!();
            eprintln!("Session complete: {:.2} mbb/hand over {} hands",
                result.mean_bb * 1000.0, result.hands_played);
        }
        Err(e) => {
            eprintln!("Session error: {}", e);
            std::process::exit(1);
        }
    }
}

/// Play against Slumbot directly from in-memory compact training state.
/// Avoids the save+reload cycle for train+play mode.
fn play_from_compact_state(
    states: [rbm_mccfr::compact_state::CompactCfrState; 2],
    postflop_states: [rbm_mccfr::rbm_buckets::PostflopState; 2],
    num_hands: u32,
    n_buckets: u32,
    assignments: &[i32; 169],
    game_config: &GameConfig,
    bucket_method: &BucketMethod,
    verbose: bool,
) {
    eprintln!();
    eprintln!("=== Slumbot Play (from training state) ===");
    eprintln!("Playing {} hands against Slumbot directly from compact state...", num_hands);
    eprintln!("P0={} P1={} info sets", states[0].len(), states[1].len());

    let play_strategy = slumbot::PlayStrategy::Compact(states);

    let mut play_config = slumbot::PlayConfig {
        n_buckets,
        preflop_assignments: *assignments,
        game_config: game_config.clone(),
        bucket_method: bucket_method.clone(),
        postflop_states,
        verbose,
    };

    match slumbot::run_session(&play_strategy, &mut play_config, num_hands) {
        Ok(result) => {
            eprintln!();
            eprintln!("Session complete: {:.2} mbb/hand over {} hands",
                result.mean_bb * 1000.0, result.hands_played);
        }
        Err(e) => {
            eprintln!("Session error: {}", e);
            std::process::exit(1);
        }
    }
}

/// Try loading a checkpoint, auto-detecting format (compact RBMCMP01 or legacy RBMRAW01).
fn load_checkpoint(path: &Path) -> (rbm_mccfr::compact_state::CompactCfrState, rbm_mccfr::compact_state::CompactCfrState, u64) {
    // Try compact first
    match checkpoint::load_compact_raw_states(path) {
        Ok((states, iter)) => {
            eprintln!("Loaded compact checkpoint: {} P0 + {} P1 info sets at iteration {}",
                states[0].len(), states[1].len(), iter);
            let [s0, s1] = states;
            return (s0, s1, iter);
        }
        Err(_) => {}
    }

    // Fall back to legacy format
    match checkpoint::load_legacy_as_compact(path) {
        Ok((states, iter)) => {
            eprintln!("Loaded legacy checkpoint (converted to compact): {} P0 + {} P1 info sets at iteration {}",
                states[0].len(), states[1].len(), iter);
            let [s0, s1] = states;
            return (s0, s1, iter);
        }
        Err(e) => {
            eprintln!("Failed to load checkpoint: {}", e);
            std::process::exit(1);
        }
    }
}

fn main() {
    let cli = parse_args();

    // --play-only mode: skip training, load strategy, play
    if cli.play_only_hands > 0 {
        let strategy_path = cli.strategy_path.as_deref()
            .expect("--play-only requires --strategy PATH");
        play_against_slumbot(
            strategy_path,
            cli.play_only_hands,
            cli.train_config.n_buckets,
            &cli.assignments,
            &cli.game_config,
            &cli.train_config.bucket_method,
            cli.verbose,
        );
        return;
    }

    let bucket_desc = match &cli.train_config.bucket_method {
        BucketMethod::Rbm { epsilon } => format!("rbm (epsilon={})", epsilon),
        BucketMethod::Equity => format!("equity ({} buckets)", cli.train_config.n_buckets),
    };

    eprintln!("=== RBM-MCCFR Training (compact i16 storage) ===");
    eprintln!("Game:       {}/{} blinds, {} stack, {} bet fracs, max {} raises",
        cli.game_config.small_blind, cli.game_config.big_blind,
        cli.game_config.starting_stack,
        cli.game_config.bet_fractions.len(),
        cli.game_config.max_raises_per_round);
    eprintln!("Training:   {} iterations, {} thread(s)",
        cli.train_config.iterations, cli.num_threads);
    eprintln!("Buckets:    {}", bucket_desc);
    eprintln!("Variants:   dcfr={} lcfr={} prune={:.0} regret_scale_every={}",
        cli.train_config.dcfr, cli.train_config.lcfr, cli.train_config.prune_threshold,
        cli.train_config.regret_scale_every);
    eprintln!("Output:     {}", cli.output);
    if cli.play_hands > 0 {
        eprintln!("Play:       {} hands against Slumbot after training", cli.play_hands);
    }
    eprintln!();

    let start = Instant::now();

    let (states, postflop_states) = if let Some(ref ckpt_path) = cli.resume_path {
        eprintln!("Resuming from checkpoint: {}", ckpt_path);
        let (s0, s1, iter) = load_checkpoint(Path::new(ckpt_path));
        let loaded = [s0, s1];

        // Try to load PostflopState from .clusters file alongside checkpoint
        let cluster_path = ckpt_path.replace(".bin", ".clusters");
        let resume_postflop = match std::fs::File::open(&cluster_path) {
            Ok(f) => {
                let mut r = std::io::BufReader::new(f);
                let ps0 = rbm_mccfr::rbm_buckets::PostflopState::load(&mut r);
                let ps1 = rbm_mccfr::rbm_buckets::PostflopState::load(&mut r);
                match (ps0, ps1) {
                    (Ok(p0), Ok(p1)) => {
                        eprintln!("Loaded cluster state: {} + {} clusters",
                            p0.total_clusters(), p1.total_clusters());
                        Some([p0, p1])
                    }
                    _ => {
                        eprintln!("Warning: failed to load cluster state from {}", cluster_path);
                        None
                    }
                }
            }
            Err(_) => None,
        };

        if cli.num_threads > 1 {
            eprintln!("Note: parallel resume not yet supported, using single-threaded");
            train::train_mccfr(&cli.game_config, &cli.train_config, &cli.assignments, Some((&loaded, iter)), resume_postflop)
        } else {
            train::train_mccfr(&cli.game_config, &cli.train_config, &cli.assignments, Some((&loaded, iter)), resume_postflop)
        }
    } else if cli.num_threads > 1 {
        train::train_mccfr_parallel(&cli.game_config, &cli.train_config, &cli.assignments, cli.num_threads)
    } else {
        train::train_mccfr(&cli.game_config, &cli.train_config, &cli.assignments, None, None)
    };

    let elapsed = start.elapsed();

    eprintln!();
    eprintln!("Training complete in {:.1}s", elapsed.as_secs_f64());
    eprintln!("P0: {} info sets ({} i16 regrets, {} f32 strats)", states[0].len(), states[0].regret_arena.len(), states[0].strategy_arena.len());
    eprintln!("P1: {} info sets ({} i16 regrets, {} f32 strats)", states[1].len(), states[1].regret_arena.len(), states[1].strategy_arena.len());

    // Memory estimate
    let regret_bytes = (states[0].regret_arena.len() + states[1].regret_arena.len()) * 2; // i16 = 2 bytes
    let strategy_bytes = (states[0].strategy_arena.len() + states[1].strategy_arena.len()) * 4; // f32 = 4 bytes
    let index_bytes = (states[0].len() + states[1].len()) * 24; // ~24 bytes per hashmap entry
    let total_mb = (regret_bytes + strategy_bytes + index_bytes) as f64 / 1024.0 / 1024.0;
    eprintln!("Memory: {:.1} MB (regret={:.1} MB, strat={:.1} MB, index={:.1} MB)",
        total_mb,
        regret_bytes as f64 / 1024.0 / 1024.0,
        strategy_bytes as f64 / 1024.0 / 1024.0,
        index_bytes as f64 / 1024.0 / 1024.0);

    // Save averaged strategy (streaming — zero extra memory)
    checkpoint::save_compact_averaged_strategy(Path::new(&cli.output), &states)
        .expect("failed to save strategy");
    eprintln!("Averaged strategy saved to: {}", cli.output);

    // Only save raw checkpoint if we actually trained (not just resuming to export)
    let did_train = cli.resume_path.is_none() || {
        let resumed_iter = cli.resume_path.as_ref().and_then(|p| {
            // Extract iteration from checkpoint filename like checkpoint_25000000.bin
            let stem = Path::new(p).file_stem()?.to_str()?;
            stem.strip_prefix("checkpoint_")?.parse::<u64>().ok()
        }).unwrap_or(0);
        resumed_iter < cli.train_config.iterations as u64
    };

    if did_train {
        let raw_path = cli.output.replace(".bin", "_raw.bin");
        checkpoint::save_compact_raw_states(Path::new(&raw_path), &states, cli.train_config.iterations)
            .expect("failed to save raw checkpoint");
        eprintln!("Compact raw checkpoint saved to: {}", raw_path);
    }

    let iters_per_sec = cli.train_config.iterations as f64 / elapsed.as_secs_f64();
    eprintln!("Speed: {:.0} iterations/sec", iters_per_sec);

    // Play against Slumbot if requested — play directly from training state,
    // no need to reload from disk (saves time and avoids OOM on large games).
    if cli.play_hands > 0 {
        play_from_compact_state(
            states,
            postflop_states,
            cli.play_hands,
            cli.train_config.n_buckets,
            &cli.assignments,
            &cli.game_config,
            &cli.train_config.bucket_method,
            cli.verbose,
        );
    }
}
