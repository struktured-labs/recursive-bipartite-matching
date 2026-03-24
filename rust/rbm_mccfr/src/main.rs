//! Standalone MCCFR training binary.
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

use std::path::Path;
use std::time::Instant;

use rbm_mccfr::checkpoint;
use rbm_mccfr::config::{GameConfig, TrainConfig};
use rbm_mccfr::train;

fn parse_args() -> (GameConfig, TrainConfig, [i32; 169], usize, String, Option<String>) {
    let args: Vec<String> = std::env::args().collect();
    let mut game_config = GameConfig::slumbot();
    let mut train_config = TrainConfig::default();
    let mut num_threads = 1usize;
    let mut output = "strategy_rust.bin".to_string();
    let mut resume_path: Option<String> = None;

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

    (game_config, train_config, assignments, num_threads, output, resume_path)
}

fn print_help() {
    eprintln!("rbm-mccfr: High-performance MCCFR training for No-Limit Hold'em");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  --iterations N       Number of MCCFR iterations (default: 1000000)");
    eprintln!("  --threads N          Number of threads (default: 1, 0 = auto-detect)");
    eprintln!("  --n-buckets N        Bucket count per street (default: 169)");
    eprintln!("  --dcfr               Enable DCFR discounting");
    eprintln!("  --lcfr               Enable LCFR linear weighting");
    eprintln!("  --output PATH        Output strategy file (default: strategy_rust.bin)");
    eprintln!("  --report-every N     Report every N iters (default: 10000)");
    eprintln!("  --checkpoint-every N Checkpoint every N iters (default: 0 = off)");
    eprintln!("  --resume PATH        Resume from raw checkpoint");
    eprintln!("  --small-blind N      Small blind size (default: 50)");
    eprintln!("  --big-blind N        Big blind size (default: 100)");
    eprintln!("  --starting-stack N   Starting stack (default: 20000)");
    eprintln!("  --max-raises N       Max raises per round (default: 4)");
    eprintln!("  --prune-threshold F  Prune threshold (default: -3e8)");
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

fn main() {
    let (game_config, train_config, assignments, num_threads, output, resume_path) = parse_args();

    eprintln!("=== RBM-MCCFR Training ===");
    eprintln!("Game:       {}/{} blinds, {} stack, {} bet fracs, max {} raises",
        game_config.small_blind, game_config.big_blind,
        game_config.starting_stack,
        game_config.bet_fractions.len(),
        game_config.max_raises_per_round);
    eprintln!("Training:   {} iterations, {} buckets, {} thread(s)",
        train_config.iterations, train_config.n_buckets, num_threads);
    eprintln!("Variants:   dcfr={} lcfr={} prune={:.0}",
        train_config.dcfr, train_config.lcfr, train_config.prune_threshold);
    eprintln!("Output:     {}", output);
    eprintln!();

    let start = Instant::now();

    let states = if let Some(ref ckpt_path) = resume_path {
        eprintln!("Resuming from checkpoint: {}", ckpt_path);
        let (loaded, iter) = checkpoint::load_raw_states(Path::new(ckpt_path))
            .expect("failed to load checkpoint");
        eprintln!("Loaded {} P0 + {} P1 info sets at iteration {}",
            loaded[0].len(), loaded[1].len(), iter);

        if num_threads > 1 {
            // For resumed parallel training, we'd need to split the loaded
            // state. For simplicity, continue single-threaded from checkpoint.
            eprintln!("Note: parallel resume not yet supported, using single-threaded");
            train::train_mccfr(&game_config, &train_config, &assignments, Some((&loaded, iter)))
        } else {
            train::train_mccfr(&game_config, &train_config, &assignments, Some((&loaded, iter)))
        }
    } else if num_threads > 1 {
        train::train_mccfr_parallel(&game_config, &train_config, &assignments, num_threads)
    } else {
        train::train_mccfr(&game_config, &train_config, &assignments, None)
    };

    let elapsed = start.elapsed();

    eprintln!();
    eprintln!("Training complete in {:.1}s", elapsed.as_secs_f64());
    eprintln!("P0: {} info sets", states[0].len());
    eprintln!("P1: {} info sets", states[1].len());

    // Save averaged strategy
    checkpoint::save_averaged_strategy(Path::new(&output), &states)
        .expect("failed to save strategy");
    eprintln!("Averaged strategy saved to: {}", output);

    // Also save raw checkpoint for potential resume
    let raw_path = output.replace(".bin", "_raw.bin");
    checkpoint::save_raw_states(Path::new(&raw_path), &states, train_config.iterations)
        .expect("failed to save raw checkpoint");
    eprintln!("Raw checkpoint saved to: {}", raw_path);

    let iters_per_sec = train_config.iterations as f64 / elapsed.as_secs_f64();
    eprintln!("Speed: {:.0} iterations/sec", iters_per_sec);
}
