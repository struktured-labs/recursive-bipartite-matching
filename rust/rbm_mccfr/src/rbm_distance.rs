/// Recursive Bipartite Matching (RBM) distance between game trees.
///
/// Ported from OCaml's lib/distance.ml. This is the core contribution of the
/// project: a tree metric that recursively applies minimum-cost bipartite
/// matching (Hungarian algorithm) to align children at each level.
///
/// Key properties:
/// - Leaf distance = |value1 - value2|
/// - Node distance = min-cost matching of children via Hungarian algorithm
/// - Unmatched children (when child counts differ) incur phantom penalties
/// - Phantom penalty = |ev(subtree)| (the `Ev` mode from OCaml)
/// - Supports depth truncation and progressive early-out

use crate::hungarian;
use crate::tree::Tree;

/// Configuration for phantom penalty computation.
/// Matches OCaml's `Distance.config.phantom_penalty`.
#[derive(Debug, Clone)]
pub enum PhantomPenalty {
    /// Penalty = |ev(subtree)|. Default and most commonly used.
    Ev,
    /// Penalty = scale * size(subtree).
    Size(f64),
    /// Fixed constant penalty.
    Constant(f64),
}

/// Configuration for RBM distance computation.
#[derive(Debug, Clone)]
pub struct Config {
    pub phantom_penalty: PhantomPenalty,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            phantom_penalty: PhantomPenalty::Ev,
        }
    }
}

/// Compute the phantom cost of an unmatched subtree.
/// Matches OCaml's `Distance.phantom_cost`.
#[inline]
fn phantom_cost(config: &Config, tree: &Tree) -> f64 {
    match &config.phantom_penalty {
        PhantomPenalty::Ev => tree.ev().abs(),
        PhantomPenalty::Size(scale) => scale * tree.size() as f64,
        PhantomPenalty::Constant(c) => *c,
    }
}

/// Compute the full RBM distance between two trees.
///
/// Recursively matches children at each level using the Hungarian algorithm.
/// - Leaf vs Leaf: |value1 - value2|
/// - Leaf vs Node: |ev(leaf) - ev(node)| + phantom_cost(node)
/// - Node vs Node: min-cost bipartite matching of children + phantom penalties
///
/// This matches OCaml's `Distance.compute`.
pub fn compute(t1: &Tree, t2: &Tree) -> f64 {
    compute_with_config(&Config::default(), t1, t2)
}

/// Compute RBM distance with a custom configuration.
pub fn compute_with_config(config: &Config, t1: &Tree, t2: &Tree) -> f64 {
    compute_impl(config, t1, t2)
}

fn compute_impl(config: &Config, t1: &Tree, t2: &Tree) -> f64 {
    match (t1, t2) {
        (Tree::Leaf { value: v1 }, Tree::Leaf { value: v2 }) => {
            (v1 - v2).abs()
        }
        (Tree::Leaf { .. }, Tree::Node { .. }) => {
            // Leaf vs node: treat leaf as node with no children
            let leaf_ev = t1.ev();
            let node_ev = t2.ev();
            (leaf_ev - node_ev).abs() + phantom_cost(config, t2)
        }
        (Tree::Node { .. }, Tree::Leaf { .. }) => {
            // Symmetric: swap and recurse
            compute_impl(config, t2, t1)
        }
        (Tree::Node { children: c1 }, Tree::Node { children: c2 }) => {
            let n1 = c1.len();
            let n2 = c2.len();
            match (n1, n2) {
                (0, 0) => 0.0,
                (0, _) => c2.iter().map(|c| phantom_cost(config, c)).sum(),
                (_, 0) => c1.iter().map(|c| phantom_cost(config, c)).sum(),
                _ => {
                    // Build cost matrix: recursive distance between each pair
                    let cost_matrix: Vec<Vec<f64>> = c1
                        .iter()
                        .map(|a| {
                            c2.iter()
                                .map(|b| compute_impl(config, a, b))
                                .collect()
                        })
                        .collect();

                    hungarian::min_cost_matching_rectangular(
                        &cost_matrix,
                        &|i| phantom_cost(config, &c1[i]),
                        &|j| phantom_cost(config, &c2[j]),
                    )
                }
            }
        }
    }
}

/// Depth-truncated RBM distance.
///
/// Recurses normally until `max_depth`, then compares subtrees by
/// |ev(T1) - ev(T2)| only. This gives a LOWER BOUND on the full distance
/// because the EV comparison is cheaper than the full recursive matching.
///
/// Matches OCaml's `Distance.compute_truncated`.
pub fn compute_truncated(t1: &Tree, t2: &Tree, max_depth: usize) -> f64 {
    compute_truncated_with_config(&Config::default(), t1, t2, max_depth)
}

/// Depth-truncated RBM distance with custom configuration.
pub fn compute_truncated_with_config(
    config: &Config,
    t1: &Tree,
    t2: &Tree,
    max_depth: usize,
) -> f64 {
    compute_truncated_impl(config, t1, t2, max_depth, 0)
}

fn compute_truncated_impl(
    config: &Config,
    t1: &Tree,
    t2: &Tree,
    max_depth: usize,
    depth: usize,
) -> f64 {
    // At or beyond max_depth: fall back to EV difference
    if depth >= max_depth {
        return (t1.ev() - t2.ev()).abs();
    }

    match (t1, t2) {
        (Tree::Leaf { value: v1 }, Tree::Leaf { value: v2 }) => {
            (v1 - v2).abs()
        }
        (Tree::Leaf { .. }, Tree::Node { .. }) => {
            let leaf_ev = t1.ev();
            let node_ev = t2.ev();
            (leaf_ev - node_ev).abs() + phantom_cost(config, t2)
        }
        (Tree::Node { .. }, Tree::Leaf { .. }) => {
            compute_truncated_impl(config, t2, t1, max_depth, depth)
        }
        (Tree::Node { children: c1 }, Tree::Node { children: c2 }) => {
            let n1 = c1.len();
            let n2 = c2.len();
            match (n1, n2) {
                (0, 0) => 0.0,
                (0, _) => c2.iter().map(|c| phantom_cost(config, c)).sum(),
                (_, 0) => c1.iter().map(|c| phantom_cost(config, c)).sum(),
                _ => {
                    let cost_matrix: Vec<Vec<f64>> = c1
                        .iter()
                        .map(|a| {
                            c2.iter()
                                .map(|b| {
                                    compute_truncated_impl(
                                        config,
                                        a,
                                        b,
                                        max_depth,
                                        depth + 1,
                                    )
                                })
                                .collect()
                        })
                        .collect();

                    hungarian::min_cost_matching_rectangular(
                        &cost_matrix,
                        &|i| phantom_cost(config, &c1[i]),
                        &|j| phantom_cost(config, &c2[j]),
                    )
                }
            }
        }
    }
}

/// Progressive RBM distance with early-out.
///
/// Computes at depth 2, then depth 4, then full depth.
/// If the lower-bound distance exceeds `threshold` at any stage, returns early.
///
/// Returns `(distance, depth_reached)` where `depth_reached` is 2, 4, or
/// `usize::MAX` for full computation.
///
/// Matches OCaml's `Distance.compute_progressive`.
pub fn compute_progressive(t1: &Tree, t2: &Tree, threshold: f64) -> (f64, usize) {
    compute_progressive_with_config(&Config::default(), t1, t2, threshold)
}

/// Progressive RBM distance with custom configuration.
pub fn compute_progressive_with_config(
    config: &Config,
    t1: &Tree,
    t2: &Tree,
    threshold: f64,
) -> (f64, usize) {
    // Depth 2: very cheap lower bound
    let d2 = compute_truncated_impl(config, t1, t2, 2, 0);
    if d2 > threshold {
        return (d2, 2);
    }

    // Depth 4: moderate cost, tighter lower bound
    let d4 = compute_truncated_impl(config, t1, t2, 4, 0);
    if d4 > threshold {
        return (d4, 4);
    }

    // Full depth: exact distance
    let d_full = compute_impl(config, t1, t2);
    (d_full, usize::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_tree_a() -> Tree {
        // Root -> [board1, board2]
        // board1 -> [leaf(1), leaf(-1)]
        // board2 -> [leaf(1), leaf(1)]
        Tree::node(vec![
            Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]),
            Tree::node(vec![Tree::leaf(1.0), Tree::leaf(1.0)]),
        ])
    }

    fn sample_tree_b() -> Tree {
        // Root -> [board1, board2]
        // board1 -> [leaf(-1), leaf(-1)]
        // board2 -> [leaf(-1), leaf(1)]
        Tree::node(vec![
            Tree::node(vec![Tree::leaf(-1.0), Tree::leaf(-1.0)]),
            Tree::node(vec![Tree::leaf(-1.0), Tree::leaf(1.0)]),
        ])
    }

    #[test]
    fn test_identical_trees_zero_distance() {
        let t = sample_tree_a();
        let d = compute(&t, &t.clone());
        assert!(
            d.abs() < 1e-10,
            "Distance between identical trees should be 0, got {}",
            d
        );
    }

    #[test]
    fn test_different_trees_positive_distance() {
        let a = sample_tree_a();
        let b = sample_tree_b();
        let d = compute(&a, &b);
        assert!(
            d > 0.0,
            "Distance between different trees should be > 0, got {}",
            d
        );
    }

    #[test]
    fn test_symmetric() {
        let a = sample_tree_a();
        let b = sample_tree_b();
        let d_ab = compute(&a, &b);
        let d_ba = compute(&b, &a);
        assert!(
            (d_ab - d_ba).abs() < 1e-10,
            "RBM distance should be symmetric: d(a,b)={} d(b,a)={}",
            d_ab,
            d_ba
        );
    }

    #[test]
    fn test_leaf_distance() {
        let a = Tree::leaf(1.0);
        let b = Tree::leaf(-1.0);
        let d = compute(&a, &b);
        assert!(
            (d - 2.0).abs() < 1e-10,
            "Leaf distance |1 - (-1)| should be 2, got {}",
            d
        );
    }

    #[test]
    fn test_single_child_nodes() {
        let a = Tree::node(vec![Tree::leaf(0.5)]);
        let b = Tree::node(vec![Tree::leaf(-0.5)]);
        let d = compute(&a, &b);
        assert!(
            (d - 1.0).abs() < 1e-10,
            "Distance should be |0.5 - (-0.5)| = 1.0, got {}",
            d
        );
    }

    #[test]
    fn test_truncated_lower_bound() {
        let a = sample_tree_a();
        let b = sample_tree_b();
        let d_full = compute(&a, &b);
        let d_trunc = compute_truncated(&a, &b, 1);
        assert!(
            d_trunc <= d_full + 1e-10,
            "Truncated distance ({}) should be <= full distance ({})",
            d_trunc,
            d_full
        );
    }

    #[test]
    fn test_truncated_at_high_depth_equals_full() {
        let a = sample_tree_a();
        let b = sample_tree_b();
        let d_full = compute(&a, &b);
        // Max depth higher than tree depth -> should equal full
        let d_trunc = compute_truncated(&a, &b, 100);
        assert!(
            (d_full - d_trunc).abs() < 1e-10,
            "Truncated at depth >> tree depth should equal full: {} vs {}",
            d_full,
            d_trunc
        );
    }

    #[test]
    fn test_progressive_early_out_low_threshold() {
        let a = sample_tree_a();
        let b = sample_tree_b();
        // Very low threshold -> should return after depth 2
        let (d, depth) = compute_progressive(&a, &b, 0.001);
        assert!(d > 0.0);
        // Should have exited early (depth 2 or 4)
        assert!(
            depth < usize::MAX,
            "Should have exited early with low threshold, but got full depth"
        );
    }

    #[test]
    fn test_progressive_high_threshold() {
        let a = sample_tree_a();
        let b = sample_tree_b();
        let d_full = compute(&a, &b);
        // Very high threshold -> should go to full depth
        let (d, depth) = compute_progressive(&a, &b, 1000.0);
        assert!(
            (d - d_full).abs() < 1e-10,
            "Progressive with high threshold should equal full: {} vs {}",
            d,
            d_full
        );
        assert_eq!(depth, usize::MAX, "Should have reached full depth");
    }

    #[test]
    fn test_leaf_vs_node() {
        let leaf = Tree::leaf(0.5);
        let node = Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]);
        // leaf ev = 0.5, node ev = 0.0
        // distance = |0.5 - 0.0| + phantom_cost(node) = 0.5 + |ev(node)| = 0.5 + 0.0 = 0.5
        let d = compute(&leaf, &node);
        assert!(
            (d - 0.5).abs() < 1e-10,
            "Leaf vs node distance should be 0.5, got {}",
            d
        );
    }

    #[test]
    fn test_unequal_children_count() {
        // Tree with 2 children vs tree with 3 children
        let a = Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]);
        let b = Tree::node(vec![
            Tree::leaf(1.0),
            Tree::leaf(-1.0),
            Tree::leaf(0.0),
        ]);
        let d = compute(&a, &b);
        // Should handle rectangular matching (phantom for extra child)
        assert!(d >= 0.0);
    }

    #[test]
    fn test_empty_node_distance() {
        let a = Tree::node(vec![]);
        let b = Tree::node(vec![]);
        let d = compute(&a, &b);
        assert!((d - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_config_constant_penalty() {
        let config = Config {
            phantom_penalty: PhantomPenalty::Constant(10.0),
        };
        let a = Tree::node(vec![Tree::leaf(1.0)]);
        let b = Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]);
        let d = compute_with_config(&config, &a, &b);
        // Matching: leaf(1) matches leaf(1) (cost 0), leaf(-1) unmatched (phantom cost 10)
        assert!(
            (d - 10.0).abs() < 1e-10,
            "With constant phantom penalty 10, distance should be 10, got {}",
            d
        );
    }

    #[test]
    fn test_config_size_penalty() {
        let config = Config {
            phantom_penalty: PhantomPenalty::Size(1.0),
        };
        let a = Tree::node(vec![Tree::leaf(1.0)]);
        let b = Tree::node(vec![
            Tree::leaf(1.0),
            Tree::node(vec![Tree::leaf(0.5), Tree::leaf(-0.5)]),
        ]);
        let d = compute_with_config(&config, &a, &b);
        // Matching: leaf(1) matches leaf(1) (cost 0), Node{leaf,leaf} unmatched
        // phantom_cost = 1.0 * size(Node{leaf,leaf}) = 1.0 * 3 = 3.0
        assert!(
            (d - 3.0).abs() < 1e-10,
            "With size phantom penalty, distance should be 3.0, got {}",
            d
        );
    }

    #[test]
    fn test_triangle_inequality() {
        // RBM distance is a metric, so triangle inequality should hold
        let a = Tree::node(vec![Tree::leaf(1.0), Tree::leaf(1.0)]);
        let b = Tree::node(vec![Tree::leaf(0.0), Tree::leaf(0.0)]);
        let c = Tree::node(vec![Tree::leaf(-1.0), Tree::leaf(-1.0)]);

        let d_ab = compute(&a, &b);
        let d_bc = compute(&b, &c);
        let d_ac = compute(&a, &c);

        assert!(
            d_ac <= d_ab + d_bc + 1e-10,
            "Triangle inequality violated: d(a,c)={} > d(a,b)+d(b,c)={}",
            d_ac,
            d_ab + d_bc
        );
    }
}
