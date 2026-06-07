//! Sketch + test: does RBM over a BETTING-subtree representation carry signal
//! that EMD-on-equity is structurally blind to?
//!
//! Motivation: the showdown-distribution tree (root -> boards -> ±1 leaves) has
//! NO betting structure, so RBM there ≈ EMD (ρ≈0.99, see rbm_vs_emd). In poker
//! the betting-tree SHAPE is hand-independent at a fixed state, so hand-vs-hand
//! is always EMD-like. Structure only varies STATE-vs-STATE: stack depth, raises
//! remaining, pot geometry. Two states can share an equity distribution yet have
//! very different remaining betting trees and play completely differently.
//!
//! This builds a synthetic (clearly not game-theoretically exact) betting
//! subtree per state, parameterized by:
//!   - e            : hero showdown equity in [0,1]
//!   - raises_left  : how many more raises allowed (controls tree DEPTH/shape)
//!   - pot, stack   : geometry (controls leaf magnitudes / stakes)
//!
//! Tree (hero perspective), recursively:
//!   node = [ hero-fold leaf, showdown leaf, raise -> deeper node (if allowed) ]
//! Leaf values are EVs in "pot fraction" units. Deeper betting = bigger pots =
//! bigger stakes, exactly the info equity alone cannot convey.
//!
//! We then compare, over many state pairs:
//!   - RBM distance (full recursive structural metric)
//!   - EMD_equity   : |e_a - e_b|              (classic equity abstraction)
//!   - EMD_leafset  : Wasserstein on the flattened leaf-value multisets
//!                    (a GENEROUS structure-blind baseline: even sees leaf counts)
//!
//! Plus a targeted probe: FIX equity, vary structure. EMD_equity = 0 there by
//! construction; if RBM spreads those pairs, it is capturing a real strategic
//! dimension EMD cannot.

use rand::Rng;
use rand::SeedableRng;
use rand_xoshiro::Xoshiro256PlusPlus;

use rbm_mccfr::rbm_distance;
use rbm_mccfr::tree::Tree;

const BET_FRAC: f64 = 0.6; // raise adds 0.6*pot; stack drained accordingly

/// Build a synthetic betting subtree from hero's perspective.
fn build_subtree(pot: f64, stack: f64, raises_left: u32, e: f64) -> Tree {
    // Showdown EV (call/check then showdown): win pot share with prob e.
    // Normalize to pot-fraction EV in [-pot, +pot].
    let showdown = (2.0 * e - 1.0) * pot;
    // Hero folds now: forfeits current investment (approx half the pot).
    let hero_fold = -0.5 * pot;

    if raises_left == 0 || stack <= 1e-6 {
        // Terminal betting: only fold or showdown.
        return Tree::node(vec![Tree::leaf(hero_fold), Tree::leaf(showdown)]);
    }

    let bet = (BET_FRAC * pot).min(stack);
    let deeper = build_subtree(pot + bet, stack - bet, raises_left - 1, e);

    Tree::node(vec![
        Tree::leaf(hero_fold),
        Tree::leaf(showdown),
        deeper,
    ])
}

fn leaf_values(t: &Tree, out: &mut Vec<f64>) {
    match t {
        Tree::Leaf { value } => out.push(*value),
        Tree::Node { children } => {
            for c in children {
                leaf_values(c, out);
            }
        }
    }
}

/// Wasserstein-1 between two scalar multisets (pad shorter with its own mean
/// so unequal sizes are handled; this is generous to the structure-blind side).
fn emd_multiset(a: &[f64], b: &[f64]) -> f64 {
    let mut sa = a.to_vec();
    let mut sb = b.to_vec();
    // Pad to equal length with the multiset mean (neutral mass).
    let pad = |v: &mut Vec<f64>, n: usize| {
        if v.len() < n {
            let m = v.iter().sum::<f64>() / v.len().max(1) as f64;
            while v.len() < n {
                v.push(m);
            }
        }
    };
    let n = sa.len().max(sb.len());
    pad(&mut sa, n);
    pad(&mut sb, n);
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

#[derive(Clone)]
struct State {
    e: f64,
    raises_left: u32,
    stack: f64,
    tree: Tree,
    leaves: Vec<f64>,
}

fn make_state(e: f64, raises_left: u32, stack: f64) -> State {
    let tree = build_subtree(0.1, stack, raises_left, e);
    let mut leaves = Vec::new();
    leaf_values(&tree, &mut leaves);
    State { e, raises_left, stack, tree, leaves }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(250);
    let mut rng = Xoshiro256PlusPlus::seed_from_u64(0xBEEF);

    // Population: equity, raises remaining, and stack all vary independently.
    let mut states: Vec<State> = Vec::with_capacity(n);
    for _ in 0..n {
        let e = rng.gen::<f64>();
        let raises_left = rng.gen_range(0..=5);
        let stack = rng.gen_range(0.2..3.0);
        states.push(make_state(e, raises_left, stack));
    }

    let mut rbm_d = Vec::new();
    let mut emd_eq = Vec::new();
    let mut emd_ls = Vec::new();
    for i in 0..n {
        for j in (i + 1)..n {
            rbm_d.push(rbm_distance::compute(&states[i].tree, &states[j].tree));
            emd_eq.push((states[i].e - states[j].e).abs());
            emd_ls.push(emd_multiset(&states[i].leaves, &states[j].leaves));
        }
    }

    println!("RBM over synthetic BETTING subtrees vs EMD baselines");
    println!("  n_states={}  pairs={}", n, rbm_d.len());
    println!("  Spearman ρ(RBM, EMD_equity scalar) = {:.4}", spearman(&rbm_d, &emd_eq));
    println!("  Spearman ρ(RBM, EMD_leafmultiset)  = {:.4}", spearman(&rbm_d, &emd_ls));
    println!();
    println!("  (Compare: showdown-tree representation gave ρ≈0.99 vs EMD.)");
    println!();

    // Targeted probe: FIX equity, vary betting structure. EMD_equity = 0 here.
    println!("PROBE: fixed equity e=0.55, vary (raises_left, stack).");
    println!("  EMD_equity is identically 0 for every pair below by construction.");
    println!("  If RBM spreads these, it sees a dimension EMD-on-equity cannot.\n");
    let grid: Vec<(u32, f64)> = vec![
        (0, 0.3), (1, 0.5), (2, 1.0), (3, 1.5), (5, 3.0),
    ];
    let probe: Vec<State> = grid.iter().map(|&(r, s)| make_state(0.55, r, s)).collect();
    println!("    state: (raises_left, stack)");
    print!("            ");
    for (r, s) in &grid {
        print!("({},{:.1})  ", r, s);
    }
    println!("\n    RBM distance matrix:");
    for a in &probe {
        print!("    ({},{:.1})  ", a.raises_left, a.stack);
        for b in &probe {
            print!("{:6.2}    ", rbm_distance::compute(&a.tree, &b.tree));
        }
        println!();
    }
    let mut probe_rbm = Vec::new();
    for i in 0..probe.len() {
        for j in (i + 1)..probe.len() {
            probe_rbm.push(rbm_distance::compute(&probe[i].tree, &probe[j].tree));
        }
    }
    probe_rbm.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "\n    Same-equity pairs: EMD_equity=0 for all; RBM range [{:.2}, {:.2}], median {:.2}",
        probe_rbm[0],
        probe_rbm[probe_rbm.len() - 1],
        probe_rbm[probe_rbm.len() / 2]
    );
}
