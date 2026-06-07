//! Phase-0 gate for the potential-aware representation port.
//!
//! Tests whether RBM over the POTENTIAL-AWARE (turn-conditional) tree carries
//! signal beyond EMD. Reports Spearman ρ vs TWO baselines:
//!   - EMD_marginal : Wasserstein on the flattened ±1 outcome multiset
//!                    (what plain equity/hand-strength bucketing sees).
//!   - EMD_turndist : Wasserstein on the per-next-card mean-equity vector
//!                    (the STRONG, potential-aware equity-distribution baseline,
//!                     i.e. Johanson-style next-street equity histograms).
//!
//! GO/NO-GO: the port is worth pursuing only if ρ(RBM, EMD_turndist) drops well
//! below the flat-tree baseline of ~0.99 (target < ~0.8). Beating only
//! EMD_marginal is necessary but not sufficient — the strong baseline is the bar.
//!
//! Run: cargo run --release --bin rbm_vs_emd_pa -- [n_hands] [street]

use rand::SeedableRng;
use rand_xoshiro::Xoshiro256PlusPlus;

use rbm_mccfr::card::{self, Card};
use rbm_mccfr::rbm_buckets::{potential_aware_tree_deep, showdown_distribution_tree};
use rbm_mccfr::rbm_distance;
use rbm_mccfr::tree::Tree;

/// Recursive (count, sum) of all leaves under a node.
fn leaf_stats(tree: &Tree) -> (usize, f64) {
    match tree {
        Tree::Leaf { value } => (1, *value),
        Tree::Node { children } => {
            let mut n = 0;
            let mut s = 0.0;
            for c in children {
                let (cn, cs) = leaf_stats(c);
                n += cn;
                s += cs;
            }
            (n, s)
        }
    }
}

/// Per-top-level-branch mean equity (the strong potential-aware EMD descriptor):
/// for a flop hand this is the per-turn-card mean over its whole river subtree.
fn branch_means(tree: &Tree) -> Vec<f64> {
    match tree {
        Tree::Node { children } => children
            .iter()
            .map(|b| {
                let (n, s) = leaf_stats(b);
                if n > 0 { s / n as f64 } else { 0.0 }
            })
            .collect(),
        Tree::Leaf { value } => vec![*value],
    }
}

fn flat_leaves(tree: &Tree, out: &mut Vec<f64>) {
    match tree {
        Tree::Leaf { value } => out.push(*value),
        Tree::Node { children } => {
            for c in children {
                flat_leaves(c, out);
            }
        }
    }
}

/// Wasserstein-1 between two scalar multisets (pad shorter with its mean).
fn emd(a: &[f64], b: &[f64]) -> f64 {
    let mut sa = a.to_vec();
    let mut sb = b.to_vec();
    let n = sa.len().max(sb.len());
    let pad = |v: &mut Vec<f64>| {
        if v.len() < n {
            let m = v.iter().sum::<f64>() / v.len().max(1) as f64;
            while v.len() < n {
                v.push(m);
            }
        }
    };
    pad(&mut sa);
    pad(&mut sb);
    sa.sort_by(|x, y| x.partial_cmp(y).unwrap());
    sb.sort_by(|x, y| x.partial_cmp(y).unwrap());
    let mut d = 0.0;
    for i in 0..n {
        d += (sa[i] - sb[i]).abs();
    }
    d / n as f64
}

fn pearson(x: &[f64], y: &[f64]) -> f64 {
    let n = x.len() as f64;
    let mx = x.iter().sum::<f64>() / n;
    let my = y.iter().sum::<f64>() / n;
    let (mut cov, mut vx, mut vy) = (0.0, 0.0, 0.0);
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

fn n_visible(street: &str) -> usize {
    match street {
        "preflop" => 0,
        "flop" => 3,
        "turn" => 4,
        _ => 5,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let n_hands: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(200);
    let street = args.get(2).map(|s| s.as_str()).unwrap_or("flop").to_string();
    // branch factors per public-card level, e.g. "10" (turn only) or "6,4" (turn+river)
    let factors: Vec<usize> = args
        .get(3)
        .map(|s| s.split(',').filter_map(|x| x.parse().ok()).collect())
        .unwrap_or_else(|| vec![10]);
    let max_leaf: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(10);
    let nvis = n_visible(&street);

    let mut rng = Xoshiro256PlusPlus::seed_from_u64(0x9E3779B9_u64.wrapping_add(nvis as u64));

    // Potential-aware trees + descriptors.
    let mut pa_trees: Vec<Tree> = Vec::with_capacity(n_hands);
    let mut bmeans: Vec<Vec<f64>> = Vec::with_capacity(n_hands);
    let mut bflat: Vec<Vec<f64>> = Vec::with_capacity(n_hands);
    // Flat showdown trees (for the contrast baseline).
    let mut flat_trees: Vec<Tree> = Vec::with_capacity(n_hands);
    let mut flat_means: Vec<Vec<f64>> = Vec::with_capacity(n_hands);

    for _ in 0..n_hands {
        let (p1, _p2, board) = card::sample_deal(&mut rng);
        let bv: &[Card] = &board[..nvis];

        let pat = potential_aware_tree_deep(&p1, bv, 0, &factors, max_leaf, &mut rng);
        bmeans.push(branch_means(&pat));
        let mut f = Vec::new();
        flat_leaves(&pat, &mut f);
        bflat.push(f);
        pa_trees.push(pat);

        let ft = showdown_distribution_tree(&p1, bv, 0, max_leaf, factors[0], &mut rng);
        flat_means.push(branch_means(&ft));
        flat_trees.push(ft);
    }

    let mut pa_rbm = Vec::new();
    let mut emd_marg = Vec::new();
    let mut emd_turn = Vec::new();
    let mut flat_rbm = Vec::new();
    let mut flat_emd = Vec::new();
    for i in 0..n_hands {
        for j in (i + 1)..n_hands {
            pa_rbm.push(rbm_distance::compute(&pa_trees[i], &pa_trees[j]));
            emd_marg.push(emd(&bflat[i], &bflat[j]));
            emd_turn.push(emd(&bmeans[i], &bmeans[j]));
            flat_rbm.push(rbm_distance::compute(&flat_trees[i], &flat_trees[j]));
            flat_emd.push(emd(&flat_means[i], &flat_means[j]));
        }
    }

    println!("Phase-0 gate: potential-aware RBM vs EMD baselines");
    println!("  street={}  n_hands={}  pairs={}", street, n_hands, pa_rbm.len());
    println!("  tree: branch_factors={:?} x {} leaves", factors, max_leaf);
    println!();
    println!("  CONTRAST (flat showdown tree):");
    println!("    Spearman ρ(flat RBM, flat EMD)        = {:.4}", spearman(&flat_rbm, &flat_emd));
    println!();
    println!("  POTENTIAL-AWARE tree:");
    println!("    Spearman ρ(PA RBM, EMD_marginal)      = {:.4}", spearman(&pa_rbm, &emd_marg));
    println!("    Spearman ρ(PA RBM, EMD_turndist) [BAR]= {:.4}", spearman(&pa_rbm, &emd_turn));
    println!();
    let bar = spearman(&pa_rbm, &emd_turn);
    if bar < 0.80 {
        println!("  => GO: ρ<0.80 vs strong baseline — PA RBM captures structure beyond EMD.");
    } else if bar < 0.95 {
        println!("  => MARGINAL: ρ in [0.80,0.95) — some extra signal; weigh cost.");
    } else {
        println!("  => NO-GO: ρ>=0.95 — PA RBM ≈ potential-aware EMD; port unlikely to help.");
    }
}
