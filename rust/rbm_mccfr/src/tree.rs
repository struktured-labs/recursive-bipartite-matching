/// Simple game tree for RBM distance computation.
///
/// Ported from OCaml's lib/tree.ml. The tree is used to represent showdown
/// distribution trees: root -> board_sample nodes -> opponent leaf nodes
/// with values in {-1, 0, +1}.
///
/// Labels are omitted in the Rust port — the RBM distance metric is
/// label-agnostic (it only compares structure and leaf values).

/// A labeled rooted tree with floating-point leaf values.
#[derive(Debug, Clone)]
pub enum Tree {
    /// Leaf node with a payoff value.
    Leaf { value: f64 },
    /// Internal node with an ordered list of children.
    Node { children: Vec<Tree> },
}

impl Tree {
    /// Create a leaf node.
    #[inline]
    pub fn leaf(value: f64) -> Self {
        Tree::Leaf { value }
    }

    /// Create an internal node.
    #[inline]
    pub fn node(children: Vec<Tree>) -> Self {
        Tree::Node { children }
    }

    /// Expected value: average of all leaf values.
    /// Matches OCaml's `Tree.ev`.
    pub fn ev(&self) -> f64 {
        let (sum, count) = self.fold_leaves(0.0, 0usize, |s, c, v| (s + v, c + 1));
        if count == 0 {
            0.0
        } else {
            sum / count as f64
        }
    }

    /// Number of leaf nodes.
    pub fn num_leaves(&self) -> usize {
        match self {
            Tree::Leaf { .. } => 1,
            Tree::Node { children } => children.iter().map(|c| c.num_leaves()).sum(),
        }
    }

    /// Total size (number of nodes including internal nodes).
    /// Matches OCaml's `Tree.size`.
    pub fn size(&self) -> usize {
        match self {
            Tree::Leaf { .. } => 1,
            Tree::Node { children } => {
                1 + children.iter().map(|c| c.size()).sum::<usize>()
            }
        }
    }

    /// Maximum depth from root to any leaf. Leaf depth = 0.
    pub fn depth(&self) -> usize {
        match self {
            Tree::Leaf { .. } => 0,
            Tree::Node { children } => {
                if children.is_empty() {
                    0
                } else {
                    1 + children.iter().map(|c| c.depth()).max().unwrap_or(0)
                }
            }
        }
    }

    /// Fold over all leaves, accumulating two values.
    fn fold_leaves<A, B, F>(&self, init_a: A, init_b: B, f: F) -> (A, B)
    where
        F: Fn(A, B, f64) -> (A, B) + Copy,
    {
        match self {
            Tree::Leaf { value } => f(init_a, init_b, *value),
            Tree::Node { children } => {
                let mut a = init_a;
                let mut b = init_b;
                for child in children {
                    let (na, nb) = child.fold_leaves(a, b, f);
                    a = na;
                    b = nb;
                }
                (a, b)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_leaf_ev() {
        let t = Tree::leaf(0.5);
        assert!((t.ev() - 0.5).abs() < 1e-10);
    }

    #[test]
    fn test_node_ev() {
        let t = Tree::node(vec![
            Tree::leaf(1.0),
            Tree::leaf(-1.0),
            Tree::leaf(0.0),
        ]);
        assert!((t.ev() - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_nested_ev() {
        // Two board samples, each with two opponent outcomes
        let t = Tree::node(vec![
            Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]),
            Tree::node(vec![Tree::leaf(1.0), Tree::leaf(1.0)]),
        ]);
        // Leaves: 1, -1, 1, 1 => average = 0.5
        assert!((t.ev() - 0.5).abs() < 1e-10);
    }

    #[test]
    fn test_num_leaves() {
        let t = Tree::node(vec![
            Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]),
            Tree::node(vec![Tree::leaf(0.0)]),
        ]);
        assert_eq!(t.num_leaves(), 3);
    }

    #[test]
    fn test_size() {
        // root(2 children) -> child1(2 leaves) + child2(1 leaf)
        // Total: 1 (root) + 1 (child1) + 2 (leaves) + 1 (child2) + 1 (leaf) = 6
        let t = Tree::node(vec![
            Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]),
            Tree::node(vec![Tree::leaf(0.0)]),
        ]);
        assert_eq!(t.size(), 6);
    }

    #[test]
    fn test_depth() {
        let t = Tree::node(vec![
            Tree::node(vec![Tree::leaf(1.0), Tree::leaf(-1.0)]),
            Tree::leaf(0.0),
        ]);
        assert_eq!(t.depth(), 2);
    }

    #[test]
    fn test_empty_node() {
        let t = Tree::node(vec![]);
        assert_eq!(t.ev(), 0.0);
        assert_eq!(t.num_leaves(), 0);
        assert_eq!(t.depth(), 0);
    }
}
