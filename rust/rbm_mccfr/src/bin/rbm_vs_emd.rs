//! Decisive test: on showdown-distribution trees, does RBM distance carry
//! signal beyond flat equity-distribution EMD?
//!
//! For each sampled hand we build ONE showdown tree (root -> board nodes ->
//! opponent {-1,0,+1} leaves). From the SAME tree we derive two things:
//!   1. The tree itself, for RBM distance (rbm_distance::compute).
//!   2. A per-board equity vector: each board node -> mean of its leaves.
//!      Flat EMD = Wasserstein-1 between two hands' sorted per-board-equity
//!      vectors. This is the standard equity-distribution abstraction metric.
//!
//! We then compute, over all hand pairs, both distances and report Pearson +
//! Spearman correlation between them.
//!
//! Interpretation:
//!   - Spearman ~1.0  => RBM is a monotone re-scaling of EMD on this
//!     representation; the recursive tree machinery earns nothing. RBM is
//!     dressed-up EMD.
//!   - Spearman noticeably < 1 => RBM ranks hand-pairs differently than EMD;
//!     there is genuine extra structural signal.
//!
//! Run: cargo run --release --bin rbm_vs_emd -- [n_hands] [street]
//!   street in {preflop, flop, turn, river} (default flop)

use rand::SeedableRng;
use rand_xoshiro::Xoshiro256PlusPlus;

use rbm_mccfr::card::{self, Card};
use rbm_mccfr::rbm_buckets::showdown_distribution_tree;
use rbm_mccfr::rbm_distance;
use rbm_mccfr::tree::Tree;

const MAX_BOARD_SAMPLES: usize = 10;
const MAX_OPPONENTS: usize = 10;

/// Per-board equity vector: for each board-sample node (child of root),
/// the mean of its opponent leaves (= equity on that board runout).
fn per_board_equities(tree: &Tree) -> Vec<f64> {
    match tree {
        Tree::Node { children } => children
            .iter()
            .map(|board| match board {
                Tree::Node { children: leaves } if !leaves.is_empty() => {
                    let s: f64 = leaves
                        .iter()
                        .map(|l| match l {
                            Tree::Leaf { value } => *value,
                            _ => 0.0,
                        })
                        .sum();
                    s / leaves.len() as f64
                }
                Tree::Leaf { value } => *value,
                _ => 0.0,
            })
            .collect(),
        Tree::Leaf { value } => vec![*value],
    }
}

/// Wasserstein-1 between two equal-length scalar samples = L1 of sorted diffs.
/// (Standard equity-distribution EMD.)
fn emd(a: &[f64], b: &[f64]) -> f64 {
    let mut sa = a.to_vec();
    let mut sb = b.to_vec();
    sa.sort_by(|x, y| x.partial_cmp(y).unwrap());
    sb.sort_by(|x, y| x.partial_cmp(y).unwrap());
    let n = sa.len().min(sb.len());
    let mut d = 0.0;
    for i in 0..n {
        d += (sa[i] - sb[i]).abs();
    }
    d
}

fn pearson(x: &[f64], y: &[f64]) -> f64 {
    let n = x.len() as f64;
    let mx = x.iter().sum::<f64>() / n;
    let my = y.iter().sum::<f64>() / n;
    let mut cov = 0.0;
    let mut vx = 0.0;
    let mut vy = 0.0;
    for i in 0..x.len() {
        let dx = x[i] - mx;
        let dy = y[i] - my;
        cov += dx * dy;
        vx += dx * dx;
        vy += dy * dy;
    }
    if vx == 0.0 || vy == 0.0 {
        return f64::NAN;
    }
    cov / (vx.sqrt() * vy.sqrt())
}

/// Fractional ranks (average ranks for ties) for Spearman.
fn ranks(v: &[f64]) -> Vec<f64> {
    let mut idx: Vec<usize> = (0..v.len()).collect();
    idx.sort_by(|&a, &b| v[a].partial_cmp(&v[b]).unwrap());
    let mut r = vec![0.0; v.len()];
    let mut i = 0;
    while i < idx.len() {
        let mut j = i;
        while j + 1 < idx.len() && v[idx[j + 1]] == v[idx[i]] {
            j += 1;
        }
        // average rank for ties spanning [i, j]
        let avg = ((i + j) as f64) / 2.0 + 1.0;
        for k in i..=j {
            r[idx[k]] = avg;
        }
        i = j + 1;
    }
    r
}

fn spearman(x: &[f64], y: &[f64]) -> f64 {
    pearson(&ranks(x), &ranks(y))
}

fn board_visible(board: &[Card; 5], street: &str) -> usize {
    match street {
        "preflop" => 0,
        "flop" => 3,
        "turn" => 4,
        _ => 5,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let n_hands: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(150);
    let street = args.get(2).map(|s| s.as_str()).unwrap_or("flop").to_string();

    let mut rng = Xoshiro256PlusPlus::seed_from_u64(0xC0FFEE);

    // Build one tree + equity vector per hand.
    let mut trees: Vec<Tree> = Vec::with_capacity(n_hands);
    let mut eqs: Vec<Vec<f64>> = Vec::with_capacity(n_hands);
    for _ in 0..n_hands {
        let (p1, _p2, board) = card::sample_deal(&mut rng);
        let nvis = board_visible(&board, &street);
        let tree = showdown_distribution_tree(
            &p1,
            &board[..nvis],
            0,
            MAX_OPPONENTS,
            MAX_BOARD_SAMPLES,
            &mut rng,
        );
        eqs.push(per_board_equities(&tree));
        trees.push(tree);
    }

    // All pairwise distances under both metrics.
    let mut rbm_d: Vec<f64> = Vec::new();
    let mut emd_d: Vec<f64> = Vec::new();
    for i in 0..n_hands {
        for j in (i + 1)..n_hands {
            rbm_d.push(rbm_distance::compute(&trees[i], &trees[j]));
            emd_d.push(emd(&eqs[i], &eqs[j]));
        }
    }

    let p = pearson(&rbm_d, &emd_d);
    let s = spearman(&rbm_d, &emd_d);

    // Summary stats
    let summ = |v: &[f64]| {
        let mut s = v.to_vec();
        s.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mean = s.iter().sum::<f64>() / s.len() as f64;
        (s[0], s[s.len() / 2], mean, s[s.len() - 1])
    };
    let (rmin, rmed, rmean, rmax) = summ(&rbm_d);
    let (emin, emed, emean, emax) = summ(&emd_d);

    println!("RBM vs EMD on showdown trees");
    println!("  street={}  n_hands={}  pairs={}", street, n_hands, rbm_d.len());
    println!(
        "  tree params: {} boards x {} opponents = {} leaves",
        MAX_BOARD_SAMPLES,
        MAX_OPPONENTS,
        MAX_BOARD_SAMPLES * MAX_OPPONENTS
    );
    println!("  RBM dist:  min={:.3} med={:.3} mean={:.3} max={:.3}", rmin, rmed, rmean, rmax);
    println!("  EMD dist:  min={:.3} med={:.3} mean={:.3} max={:.3}", emin, emed, emean, emax);
    println!();
    println!("  Pearson  r = {:.4}", p);
    println!("  Spearman ρ = {:.4}", s);
    println!();
    if s > 0.95 {
        println!("  => ρ>0.95: RBM is ~a monotone rescale of EMD here. Recursion earns little.");
    } else if s > 0.85 {
        println!("  => ρ in (0.85,0.95]: mostly EMD, modest extra signal.");
    } else {
        println!("  => ρ<=0.85: RBM ranks pairs materially differently than EMD.");
    }
}
