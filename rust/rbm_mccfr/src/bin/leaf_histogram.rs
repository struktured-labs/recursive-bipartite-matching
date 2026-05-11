//! Tier-1 leaf-count diagnostic: are showdown distribution trees at 10 leaves
//! actually distinguishable enough to support fine-grained RBM clustering?
//!
//! Samples N preflop hands and N flop hands, builds two showdown trees per
//! hand (one at 10 leaves, one at 50 leaves), then computes ALL pairwise RBM
//! distances within each tree set. Writes the resulting distances to two CSV
//! files for plotting.
//!
//! If 10-leaf trees pile up at distance 0/1/2 (lots of "false equivalences"
//! due to integer quantization) and 50-leaf trees disperse smoothly across
//! [0, 100], that's evidence more sampling resolution is worth optimizing.
//! If both histograms look similar after rescaling, sampling doesn't matter.

use rand::SeedableRng;
use rand_xoshiro::Xoshiro256PlusPlus;
use std::fs::File;
use std::io::{BufWriter, Write};

use rbm_mccfr::card::{self, Card};
use rbm_mccfr::rbm_buckets::showdown_distribution_tree;
use rbm_mccfr::rbm_distance::{self, Config as RbmConfig};
use rbm_mccfr::tree::Tree;

fn sample_hand(rng: &mut impl rand::Rng) -> [Card; 2] {
    let mut deck: [Card; 52] = std::array::from_fn(|i| i as u8);
    for i in 0..2 {
        let j = i + (rng.gen::<u32>() as usize % (52 - i));
        deck.swap(i, j);
    }
    [deck[0], deck[1]]
}

fn sample_flop(rng: &mut impl rand::Rng, hole: &[Card; 2]) -> [Card; 3] {
    let mut deck: Vec<Card> = (0..52u8).filter(|c| !hole.contains(c)).collect();
    for i in 0..3 {
        let j = i + (rng.gen::<u32>() as usize % (deck.len() - i));
        deck.swap(i, j);
    }
    [deck[0], deck[1], deck[2]]
}

fn build_trees<R: rand::Rng>(
    n: usize,
    leaves_board: usize,
    leaves_opp: usize,
    label: &str,
    rng: &mut R,
) -> (Vec<Tree>, Vec<Tree>) {
    eprintln!("[{}] building {} preflop + {} flop trees ({}×{}={} leaves each)",
        label, n, n, leaves_board, leaves_opp, leaves_board * leaves_opp);
    let mut preflop = Vec::with_capacity(n);
    let mut flop = Vec::with_capacity(n);
    for _ in 0..n {
        let hole = sample_hand(rng);
        let pre_tree = showdown_distribution_tree(&hole, &[], 0, leaves_opp, leaves_board, rng);
        preflop.push(pre_tree);
        let flop_cards = sample_flop(rng, &hole);
        let flop_tree = showdown_distribution_tree(&hole, &flop_cards, 0, leaves_opp, leaves_board, rng);
        flop.push(flop_tree);
    }
    (preflop, flop)
}

fn pairwise_distances(trees: &[Tree], cap: f64) -> Vec<f64> {
    let n = trees.len();
    let mut out = Vec::with_capacity(n * (n - 1) / 2);
    let cfg = RbmConfig::default();
    for i in 0..n {
        for j in (i + 1)..n {
            // No early-out for the histogram: pass huge cap to force full
            // distance compute. This is more expensive but gives us the
            // honest distance distribution.
            let (d, _) = rbm_distance::compute_progressive_with_config(&cfg, &trees[i], &trees[j], cap);
            out.push(d);
        }
    }
    out
}

fn cross_distances(a: &[Tree], b: &[Tree]) -> Vec<f64> {
    let cfg = RbmConfig::default();
    let mut out = Vec::with_capacity(a.len() * b.len());
    for ti in a {
        for tj in b {
            let (d, _) = rbm_distance::compute_progressive_with_config(&cfg, ti, tj, 1e9);
            out.push(d);
        }
    }
    out
}

fn pooled_distances(trees: &[&Tree]) -> Vec<f64> {
    let n = trees.len();
    let mut out = Vec::with_capacity(n * (n - 1) / 2);
    let cfg = RbmConfig::default();
    for i in 0..n {
        for j in (i + 1)..n {
            let (d, _) = rbm_distance::compute_progressive_with_config(&cfg, trees[i], trees[j], 1e9);
            out.push(d);
        }
    }
    out
}

fn write_csv(path: &str, label: &str, distances: &[f64]) -> std::io::Result<()> {
    let f = File::create(path)?;
    let mut w = BufWriter::new(f);
    writeln!(w, "label,distance")?;
    for d in distances {
        writeln!(w, "{},{}", label, d)?;
    }
    Ok(())
}

fn summary(label: &str, distances: &[f64]) {
    let n = distances.len();
    if n == 0 { return; }
    let mut sorted = distances.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mean: f64 = distances.iter().sum::<f64>() / n as f64;
    let var: f64 = distances.iter().map(|d| (d - mean).powi(2)).sum::<f64>() / n as f64;
    let p25 = sorted[n / 4];
    let p50 = sorted[n / 2];
    let p75 = sorted[3 * n / 4];
    let n_zero = distances.iter().filter(|&&d| d <= 0.5).count();
    let pct_zero = 100.0 * n_zero as f64 / n as f64;
    eprintln!(
        "[{}] n={} mean={:.2} sd={:.2} p25={:.2} p50={:.2} p75={:.2} pct_zero={:.1}% (dist<=0.5)",
        label, n, mean, var.sqrt(), p25, p50, p75, pct_zero
    );
}

fn main() {
    let n_hands = 200; // 200 hands × 2 stages × 2 leaf-configs = 4 × C(200,2) = 79,600 distance computes
    let seed = 0xC0FFEE_u64;
    let outdir = "/home/struktured/projects/recursive-bipartite-matching/tmp/leaf_histogram";
    std::fs::create_dir_all(outdir).ok();

    eprintln!("=== Leaf-count histogram diagnostic (seed={}, n_hands={}) ===", seed, n_hands);

    let mut rng = Xoshiro256PlusPlus::seed_from_u64(seed);
    // Build same hand list under both configurations using a snapshot+rewind trick:
    // simplest is to use independent RNGs reset to same seed for the sampling
    // of (hole, flop), and only diverge on the tree's MC samples.
    // Practically: just build them in two separate phases with re-seeded RNGs.
    let mut rng_sample_10 = Xoshiro256PlusPlus::seed_from_u64(seed);
    let (pre_10, flop_10) = build_trees(n_hands, 2, 5, "10-leaf", &mut rng_sample_10);
    let mut rng_sample_50 = Xoshiro256PlusPlus::seed_from_u64(seed);
    let (pre_50, flop_50) = build_trees(n_hands, 5, 10, "50-leaf", &mut rng_sample_50);
    let _ = &mut rng;

    eprintln!("[10-leaf preflop] computing pairwise distances...");
    let pre_10_d = pairwise_distances(&pre_10, 1e9);
    summary("10-leaf preflop", &pre_10_d);
    eprintln!("[10-leaf flop] computing pairwise distances...");
    let flop_10_d = pairwise_distances(&flop_10, 1e9);
    summary("10-leaf flop", &flop_10_d);
    eprintln!("[50-leaf preflop] computing pairwise distances...");
    let pre_50_d = pairwise_distances(&pre_50, 1e9);
    summary("50-leaf preflop", &pre_50_d);
    eprintln!("[50-leaf flop] computing pairwise distances...");
    let flop_50_d = pairwise_distances(&flop_50, 1e9);
    summary("50-leaf flop", &flop_50_d);

    // Cross-street distances (preflop tree -> flop tree). Tells us whether
    // unified RBM naturally separates streets (cross > within) or mixes them
    // (cross ~ within).
    eprintln!("[10-leaf cross-street] computing preflop vs flop distances...");
    let cross_10 = cross_distances(&pre_10, &flop_10);
    summary("10-leaf cross", &cross_10);
    eprintln!("[50-leaf cross-street] computing preflop vs flop distances...");
    let cross_50 = cross_distances(&pre_50, &flop_50);
    summary("50-leaf cross", &cross_50);

    // Pooled — what the unified RBM clusterer actually sees: ALL trees in one
    // bag, all pairwise distances. (preflop ∪ flop) × (preflop ∪ flop).
    eprintln!("[10-leaf pooled] computing pooled pairwise distances...");
    let pool_10: Vec<&Tree> = pre_10.iter().chain(flop_10.iter()).collect();
    let pool_10_d = pooled_distances(&pool_10);
    summary("10-leaf pooled", &pool_10_d);
    eprintln!("[50-leaf pooled] computing pooled pairwise distances...");
    let pool_50: Vec<&Tree> = pre_50.iter().chain(flop_50.iter()).collect();
    let pool_50_d = pooled_distances(&pool_50);
    summary("50-leaf pooled", &pool_50_d);

    write_csv(&format!("{}/10leaf_preflop.csv", outdir), "10leaf_preflop", &pre_10_d).unwrap();
    write_csv(&format!("{}/10leaf_flop.csv", outdir), "10leaf_flop", &flop_10_d).unwrap();
    write_csv(&format!("{}/50leaf_preflop.csv", outdir), "50leaf_preflop", &pre_50_d).unwrap();
    write_csv(&format!("{}/50leaf_flop.csv", outdir), "50leaf_flop", &flop_50_d).unwrap();
    write_csv(&format!("{}/10leaf_cross.csv", outdir), "10leaf_cross", &cross_10).unwrap();
    write_csv(&format!("{}/50leaf_cross.csv", outdir), "50leaf_cross", &cross_50).unwrap();
    write_csv(&format!("{}/10leaf_pooled.csv", outdir), "10leaf_pooled", &pool_10_d).unwrap();
    write_csv(&format!("{}/50leaf_pooled.csv", outdir), "50leaf_pooled", &pool_50_d).unwrap();
    eprintln!("CSVs written to {}", outdir);
}
