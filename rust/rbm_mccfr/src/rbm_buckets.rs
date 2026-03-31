/// RBM-based post-flop bucketing for MCCFR training.
///
/// Ported from OCaml's lib/compact_cfr.ml (compute_bucket_rbm_postflop,
/// find_nearest_postflop_cluster, precompute_buckets_rbm) and
/// lib/nolimit_holdem.ml (showdown_distribution_tree).
///
/// Each hand is represented by a showdown distribution tree:
///   root -> board_sample nodes -> opponent leaf nodes with value {-1, 0, +1}
///
/// Hands with similar distribution trees (small RBM distance) are clustered
/// together. New clusters are created online when no existing cluster is
/// within epsilon of the new hand's tree.

use rand::Rng;

use crate::card::Card;
use crate::hand_eval_fast;
use crate::rbm_distance::{self, Config as RbmConfig};
use crate::tree::Tree;
use crate::buckets;

/// Default MC sampling parameters for showdown distribution trees.
/// Matches OCaml: 2 board completions × 5 opponent hands = 10 leaves.
/// With deterministic seeds (0 intra-hand noise) and normalized distances,
/// these small trees are sufficient for epsilon=0.5 clustering while keeping
/// the hot loop fast (~16ns per showdown × 10 = 160ns per tree).
const DEFAULT_MAX_BOARD_SAMPLES: usize = 2;
const DEFAULT_MAX_OPPONENTS: usize = 5;

/// A cluster of strategically similar hands.
#[derive(Debug, Clone)]
pub struct PostflopCluster {
    /// Showdown distribution tree of the cluster representative.
    pub representative: Tree,
    /// Cached EV of the representative tree (for fast EV pre-filtering).
    pub rep_ev: f64,
    /// Number of hands assigned to this cluster.
    pub member_count: u32,
}

/// Per-player mutable cluster state for post-flop RBM bucketing.
///
/// Clusters are indexed by street:
///   - street 1 = flop (3 board cards visible)
///   - street 2 = turn (4 board cards visible)
///   - street 3 = river (5 board cards visible)
///
/// The cluster lists grow during training as new distinct hands are encountered.
#[derive(Debug, Clone)]
pub struct PostflopState {
    /// clusters[street_idx] is the list of clusters for that street.
    /// street_idx 0 = flop (round_idx=1), 1 = turn (round_idx=2), 2 = river (round_idx=3).
    pub clusters: [Vec<PostflopCluster>; 3],
}

impl PostflopState {
    /// Create a new empty post-flop state.
    pub fn new() -> Self {
        PostflopState {
            clusters: [Vec::new(), Vec::new(), Vec::new()],
        }
    }

    /// Get total cluster count across all streets.
    pub fn total_clusters(&self) -> usize {
        self.clusters.iter().map(|c| c.len()).sum()
    }

    /// Serialize to a writer. Format:
    ///   For each of 3 streets:
    ///     n_clusters: u32
    ///     For each cluster:
    ///       rep_ev: f64, member_count: u32
    ///       tree (recursive): tag u8 (0=leaf, 1=node) + data
    pub fn save(&self, w: &mut impl std::io::Write) -> std::io::Result<()> {
        for street in &self.clusters {
            w.write_all(&(street.len() as u32).to_le_bytes())?;
            for cluster in street {
                w.write_all(&cluster.rep_ev.to_le_bytes())?;
                w.write_all(&cluster.member_count.to_le_bytes())?;
                Self::save_tree(w, &cluster.representative)?;
            }
        }
        Ok(())
    }

    /// Deserialize from a reader.
    pub fn load(r: &mut impl std::io::Read) -> std::io::Result<Self> {
        let mut clusters: [Vec<PostflopCluster>; 3] = [Vec::new(), Vec::new(), Vec::new()];
        for street in &mut clusters {
            let mut buf4 = [0u8; 4];
            r.read_exact(&mut buf4)?;
            let n = u32::from_le_bytes(buf4) as usize;
            *street = Vec::with_capacity(n);
            for _ in 0..n {
                let mut buf8 = [0u8; 8];
                r.read_exact(&mut buf8)?;
                let rep_ev = f64::from_le_bytes(buf8);
                r.read_exact(&mut buf4)?;
                let member_count = u32::from_le_bytes(buf4);
                let representative = Self::load_tree(r)?;
                street.push(PostflopCluster { representative, rep_ev, member_count });
            }
        }
        Ok(PostflopState { clusters })
    }

    fn save_tree(w: &mut impl std::io::Write, tree: &Tree) -> std::io::Result<()> {
        match tree {
            Tree::Leaf { value } => {
                w.write_all(&[0u8])?; // tag
                w.write_all(&value.to_le_bytes())?;
            }
            Tree::Node { children } => {
                w.write_all(&[1u8])?; // tag
                w.write_all(&(children.len() as u32).to_le_bytes())?;
                for child in children {
                    Self::save_tree(w, child)?;
                }
            }
        }
        Ok(())
    }

    fn load_tree(r: &mut impl std::io::Read) -> std::io::Result<Tree> {
        let mut tag = [0u8; 1];
        r.read_exact(&mut tag)?;
        match tag[0] {
            0 => {
                let mut buf8 = [0u8; 8];
                r.read_exact(&mut buf8)?;
                Ok(Tree::Leaf { value: f64::from_le_bytes(buf8) })
            }
            1 => {
                let mut buf4 = [0u8; 4];
                r.read_exact(&mut buf4)?;
                let n = u32::from_le_bytes(buf4) as usize;
                let mut children = Vec::with_capacity(n);
                for _ in 0..n {
                    children.push(Self::load_tree(r)?);
                }
                Ok(Tree::Node { children })
            }
            _ => Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "bad tree tag")),
        }
    }
}

impl Default for PostflopState {
    fn default() -> Self {
        Self::new()
    }
}

/// Build a showdown distribution tree for a hand at a given board state.
///
/// Samples opponent hands and board completions via Fisher-Yates partial
/// shuffle to create a compact tree capturing the hand's strength distribution.
///
/// Tree structure: root -> board_sample nodes -> opponent leaf nodes
/// Leaf values: +1 (win), 0 (tie), -1 (loss) from the perspective of `player`.
///
/// Ported from OCaml's Nolimit_holdem.showdown_distribution_tree.
///
/// # Arguments
/// - `hole_cards`: the player's 2 hole cards
/// - `board_visible`: visible board cards (3 for flop, 4 for turn, 5 for river)
/// - `player`: 0 or 1 (determines sign convention for win/loss)
/// - `max_opponents`: max opponent hands to sample per board completion
/// - `max_board_samples`: max board completions to sample
/// - `rng`: random number generator
pub fn showdown_distribution_tree(
    hole_cards: &[Card; 2],
    board_visible: &[Card],
    player: u8,
    max_opponents: usize,
    max_board_samples: usize,
    rng: &mut impl Rng,
) -> Tree {
    let h1 = hole_cards[0];
    let h2 = hole_cards[1];

    // Build the set of remaining cards (deck minus dealt cards)
    let mut dealt = [false; 52];
    dealt[h1 as usize] = true;
    dealt[h2 as usize] = true;
    for &c in board_visible {
        dealt[c as usize] = true;
    }

    let mut remaining: Vec<Card> = (0..52u8).filter(|&c| !dealt[c as usize]).collect();
    let n_rem = remaining.len();
    let n_board_needed = 5 - board_visible.len();

    let mut board_children = Vec::with_capacity(max_board_samples);

    for _ in 0..max_board_samples {
        // Fisher-Yates partial shuffle for board completions + opponent cards
        let n_shuffle = (n_board_needed + 2).min(n_rem);
        for i in 0..n_shuffle {
            let j = i + (rng.gen::<u32>() as usize % (n_rem - i));
            remaining.swap(i, j);
        }

        // Build the full 5-card board
        let mut full_board = [0u8; 5];
        for (i, &c) in board_visible.iter().enumerate() {
            full_board[i] = c;
        }
        for i in 0..n_board_needed.min(n_rem) {
            full_board[board_visible.len() + i] = remaining[i];
        }

        // Sample opponents from remaining cards after board completion
        let opp_start = n_board_needed;
        let n_opp_available = (n_rem - opp_start) / 2;
        let n_opps = max_opponents.min(n_opp_available);

        // Partial shuffle for opponent hands
        let n_opp_shuffle = (opp_start + n_opps * 2).min(n_rem);
        for i in opp_start..n_opp_shuffle {
            let j = i + (rng.gen::<u32>() as usize % (n_rem - i));
            remaining.swap(i, j);
        }

        let mut opp_leaves = Vec::with_capacity(n_opps);
        for k in 0..n_opps {
            let o1 = remaining[opp_start + k * 2];
            let o2 = remaining[opp_start + k * 2 + 1];

            // Build 7-card hands for comparison
            let mut p1h = [0u8; 7];
            p1h[0] = h1;
            p1h[1] = h2;
            p1h[2..7].copy_from_slice(&full_board);

            let mut p2h = [0u8; 7];
            p2h[0] = o1;
            p2h[1] = o2;
            p2h[2..7].copy_from_slice(&full_board);

            let cmp = hand_eval_fast::compare_hands7_fast(&p1h, &p2h);

            let value = if player == 0 {
                if cmp > 0 { 1.0 } else if cmp == 0 { 0.0 } else { -1.0 }
            } else {
                if cmp > 0 { -1.0 } else if cmp == 0 { 0.0 } else { 1.0 }
            };

            opp_leaves.push(Tree::leaf(value));
        }

        board_children.push(Tree::node(opp_leaves));
    }

    Tree::node(board_children)
}

/// Find the nearest existing cluster to a tree, with EV pre-filtering and
/// progressive distance computation for early-out.
///
/// Returns `Some((cluster_index, raw_distance))` if any clusters exist,
/// or `None` if the cluster list is empty.
///
/// Uses raw RBM distance (not normalized). For (2 boards × 5 opponents)
/// trees with leaf values in {-1, 0, 1}, the distance range is [0, 20].
/// An epsilon of 0.5 is tight — only strategically near-identical hands merge.
fn find_nearest_postflop_cluster(
    clusters: &[PostflopCluster],
    tree: &Tree,
    epsilon: f64,
    rbm_config: &RbmConfig,
) -> Option<(usize, f64)> {
    if clusters.is_empty() {
        return None;
    }

    let tree_ev = tree.ev();
    let mut best_idx = 0usize;
    let mut best_dist = f64::INFINITY;

    for (i, cluster) in clusters.iter().enumerate() {
        // EV pre-filter: |ev_diff| * num_leaves is a loose lower bound on
        // the raw distance. Skip clusters where even this bound exceeds epsilon.
        let ev_diff = (tree_ev - cluster.rep_ev).abs();
        if ev_diff > epsilon {
            continue;
        }
        if ev_diff >= best_dist {
            continue;
        }

        // Progressive RBM distance with early-out at epsilon
        let (d, _depth) = rbm_distance::compute_progressive_with_config(
            rbm_config,
            tree,
            &cluster.representative,
            epsilon,
        );

        if d < best_dist {
            best_idx = i;
            best_dist = d;
        }
    }

    Some((best_idx, best_dist))
}

/// Compute the RBM-based post-flop bucket for a hand.
///
/// Builds a showdown distribution tree using the shared training RNG
/// (matching OCaml's approach — no deterministic seeds, no cache).
/// Each call produces a fresh random tree, which may classify differently
/// than previous calls for the same hand. This is intentional: OCaml's
/// random tree noise acts as implicit regularization, producing ~400
/// clusters vs ~1200 with deterministic seeds at epsilon=0.5.
///
/// Returns the bucket index (cluster index for this street).
pub fn compute_bucket_rbm_postflop(
    hole_cards: &[Card; 2],
    board: &[Card; 5],
    round_idx: u8,
    player: u8,
    epsilon: f64,
    rbm_config: &RbmConfig,
    postflop: &mut PostflopState,
    rng: &mut impl Rng,
) -> u32 {
    // Extract visible board cards based on street
    let board_visible: &[Card] = match round_idx {
        1 => &board[..3], // flop
        2 => &board[..4], // turn
        _ => &board[..5], // river
    };

    // Build showdown distribution tree with shared RNG (like OCaml).
    // No cache — each call gets a fresh random tree.
    let tree = showdown_distribution_tree(
        hole_cards,
        board_visible,
        player,
        DEFAULT_MAX_OPPONENTS,
        DEFAULT_MAX_BOARD_SAMPLES,
        rng,
    );

    // Map round_idx to cluster array index (round 1->0, 2->1, 3->2)
    let street_idx = (round_idx - 1) as usize;
    debug_assert!(street_idx < 3, "Invalid street index: {}", street_idx);

    let clusters = &postflop.clusters[street_idx];
    let nearest = find_nearest_postflop_cluster(clusters, &tree, epsilon, rbm_config);

    match nearest {
        Some((idx, d)) => {
            if d < epsilon {
                postflop.clusters[street_idx][idx].member_count += 1;
                idx as u32
            } else {
                let new_cluster = PostflopCluster {
                    rep_ev: tree.ev(),
                    representative: tree,
                    member_count: 1,
                };
                let new_idx = postflop.clusters[street_idx].len();
                postflop.clusters[street_idx].push(new_cluster);
                new_idx as u32
            }
        }
        None => {
            let new_cluster = PostflopCluster {
                rep_ev: tree.ev(),
                representative: tree,
                member_count: 1,
            };
            postflop.clusters[street_idx].push(new_cluster);
            0
        }
    }
}

/// Precompute all 4 street buckets for a deal using RBM.
///
/// - Round 0 (preflop): uses the canonical hand ID -> preflop_assignments lookup
///   (same as equity bucketing for preflop).
/// - Rounds 1-3 (flop/turn/river): uses RBM-based clustering with shared RNG.
///
/// `player` (0 or 1) determines the sign convention for showdown outcomes.
pub fn precompute_buckets_rbm(
    hole_cards: &[Card; 2],
    board: &[Card; 5],
    preflop_assignments: &[i32; 169],
    player: u8,
    epsilon: f64,
    rbm_config: &RbmConfig,
    postflop: &mut PostflopState,
    rng: &mut impl Rng,
) -> [u32; 4] {
    let mut result = [0u32; 4];

    // Round 0: preflop uses canonical hand bucketing (same as equity)
    let cid = buckets::canonical_hand_id(hole_cards[0], hole_cards[1]);
    let preflop_bucket = preflop_assignments[cid];
    result[0] = if preflop_bucket >= 0 {
        preflop_bucket as u32
    } else {
        0
    };

    // Rounds 1-3: RBM-based post-flop bucketing (shared RNG, like OCaml)
    for round_idx in 1..=3u8 {
        result[round_idx as usize] = compute_bucket_rbm_postflop(
            hole_cards,
            board,
            round_idx,
            player,
            epsilon,
            rbm_config,
            postflop,
            rng,
        );
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::card;
    use rand::SeedableRng;
    use rand_xoshiro::Xoshiro256PlusPlus;

    #[test]
    fn test_showdown_distribution_tree_structure() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let (p1, _p2, board) = card::sample_deal(&mut rng);

        // Flop: 3 visible board cards
        let tree = showdown_distribution_tree(&p1, &board[..3], 0, 5, 2, &mut rng);

        // Root should have 2 children (max_board_samples = 2)
        match &tree {
            Tree::Node { children } => {
                assert_eq!(
                    children.len(),
                    2,
                    "Root should have max_board_samples children"
                );
                // Each child should have opponent leaves
                for child in children {
                    match child {
                        Tree::Node { children: leaves } => {
                            assert!(
                                !leaves.is_empty(),
                                "Each board sample should have opponent leaves"
                            );
                            for leaf in leaves {
                                match leaf {
                                    Tree::Leaf { value } => {
                                        assert!(
                                            *value == 1.0 || *value == 0.0 || *value == -1.0,
                                            "Leaf values should be -1, 0, or 1, got {}",
                                            value
                                        );
                                    }
                                    _ => panic!("Expected leaf node in opponent position"),
                                }
                            }
                        }
                        _ => panic!("Expected node for board sample"),
                    }
                }
            }
            _ => panic!("Root should be a node"),
        }
    }

    #[test]
    fn test_showdown_tree_ev_range() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(99);

        for _ in 0..100 {
            let (p1, _p2, board) = card::sample_deal(&mut rng);
            let tree = showdown_distribution_tree(&p1, &board[..3], 0, 10, 3, &mut rng);
            let ev = tree.ev();
            assert!(
                ev >= -1.0 && ev <= 1.0,
                "EV should be in [-1, 1], got {}",
                ev
            );
        }
    }

    #[test]
    fn test_showdown_tree_river_no_board_completion() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(77);
        let (p1, _p2, board) = card::sample_deal(&mut rng);

        // River: all 5 board cards visible, no board completion needed
        let tree = showdown_distribution_tree(&p1, &board[..5], 0, 5, 3, &mut rng);
        match &tree {
            Tree::Node { children } => {
                assert_eq!(children.len(), 3);
            }
            _ => panic!("Root should be a node"),
        }
    }

    #[test]
    fn test_identical_hands_high_epsilon() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let (p1, _p2, board) = card::sample_deal(&mut rng);
        let rbm_config = RbmConfig::default();
        let mut postflop = PostflopState::new();

        // With high epsilon (10.0), even noisy trees should merge into 1 cluster
        let b1 = compute_bucket_rbm_postflop(
            &p1, &board, 1, 0, 10.0, &rbm_config, &mut postflop, &mut rng,
        );
        let b2 = compute_bucket_rbm_postflop(
            &p1, &board, 1, 0, 10.0, &rbm_config, &mut postflop, &mut rng,
        );
        assert_eq!(
            postflop.clusters[0].len(),
            1,
            "With high epsilon, same hand should create only 1 cluster, got {}",
            postflop.clusters[0].len()
        );
        assert_eq!(b1, b2);
    }

    #[test]
    fn test_same_seed_produces_identical_trees() {
        // Same RNG seed → same tree
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let (p1, _p2, board) = card::sample_deal(&mut rng);
        let board_vis = &board[..3];

        let mut rng1 = Xoshiro256PlusPlus::seed_from_u64(99);
        let mut rng2 = Xoshiro256PlusPlus::seed_from_u64(99);

        let tree1 = showdown_distribution_tree(&p1, board_vis, 0, 10, 5, &mut rng1);
        let tree2 = showdown_distribution_tree(&p1, board_vis, 0, 10, 5, &mut rng2);

        assert_eq!(tree1.ev(), tree2.ev());
        let d = crate::rbm_distance::compute(&tree1, &tree2);
        assert_eq!(d, 0.0, "Same seed must produce distance=0 trees");
    }

    #[test]
    fn test_precompute_buckets_rbm_returns_4() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(123);
        let (p1, _p2, board) = card::sample_deal(&mut rng);
        let rbm_config = RbmConfig::default();
        let mut postflop = PostflopState::new();

        let mut assignments = [0i32; 169];
        for (i, a) in assignments.iter_mut().enumerate() {
            *a = (i % 50) as i32;
        }

        let buckets = precompute_buckets_rbm(
            &p1,
            &board,
            &assignments,
            0, // player
            0.5,
            &rbm_config,
            &mut postflop,
            &mut rng,
        );

        assert!(
            buckets[0] < 50,
            "Preflop bucket should be < 50, got {}",
            buckets[0]
        );
        for round in 1..4 {
            let _ = buckets[round];
        }
    }

    #[test]
    fn test_rbm_creates_multiple_clusters() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let rbm_config = RbmConfig::default();
        let mut postflop = PostflopState::new();

        let mut assignments = [0i32; 169];
        for (i, a) in assignments.iter_mut().enumerate() {
            *a = (i % 50) as i32;
        }

        // Process many different hands with tight epsilon -> should create many clusters
        for _ in 0..50 {
            let (p1, _p2, board) = card::sample_deal(&mut rng);
            precompute_buckets_rbm(
                &p1,
                &board,
                &assignments,
                0,
                0.05,
                &rbm_config,
                &mut postflop,
                &mut rng,
            );
        }

        let total = postflop.total_clusters();
        assert!(
            total > 10,
            "With tight epsilon, should create many clusters, got {}",
            total
        );
    }

    #[test]
    fn test_rbm_loose_epsilon_fewer_clusters() {
        let mut rng_tight = Xoshiro256PlusPlus::seed_from_u64(42);
        let mut rng_loose = Xoshiro256PlusPlus::seed_from_u64(42);
        let rbm_config = RbmConfig::default();
        let mut postflop_tight = PostflopState::new();
        let mut postflop_loose = PostflopState::new();

        let mut assignments = [0i32; 169];
        for (i, a) in assignments.iter_mut().enumerate() {
            *a = (i % 50) as i32;
        }

        // Same deals, different epsilons
        for _ in 0..30 {
            let (p1_t, _p2_t, board_t) = card::sample_deal(&mut rng_tight);
            let (p1_l, _p2_l, board_l) = card::sample_deal(&mut rng_loose);

            precompute_buckets_rbm(
                &p1_t,
                &board_t,
                &assignments,
                0,
                0.05,
                &rbm_config,
                &mut postflop_tight,
                &mut rng_tight,
            );
            precompute_buckets_rbm(
                &p1_l,
                &board_l,
                &assignments,
                0,
                2.0,
                &rbm_config,
                &mut postflop_loose,
                &mut rng_loose,
            );
        }

        let tight_total = postflop_tight.total_clusters();
        let loose_total = postflop_loose.total_clusters();
        assert!(
            tight_total >= loose_total,
            "Tight epsilon ({}) should create >= clusters than loose epsilon ({})",
            tight_total,
            loose_total
        );
    }

    #[test]
    fn test_larger_trees_lower_normalized_noise() {
        // Verify that larger MC samples (10 opp, 5 boards) have lower
        // NORMALIZED same-hand distance than smaller trees (5 opp, 2 boards).
        // Raw distances scale with tree size, but normalized (per-leaf-pair)
        // distances decrease with more samples (law of large numbers).
        use crate::rbm_distance;

        let mut deal_rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let n_trials = 50;
        let mut norm_small = Vec::new();
        let mut norm_large = Vec::new();

        for _ in 0..n_trials {
            let (p1, _p2, board) = card::sample_deal(&mut deal_rng);

            // Small trees: 5 opp, 2 boards → normalize by 10
            let mut r1 = Xoshiro256PlusPlus::seed_from_u64(deal_rng.gen());
            let mut r2 = Xoshiro256PlusPlus::seed_from_u64(deal_rng.gen());
            let t1s = showdown_distribution_tree(&p1, &board[..3], 0, 5, 2, &mut r1);
            let t2s = showdown_distribution_tree(&p1, &board[..3], 0, 5, 2, &mut r2);
            norm_small.push(rbm_distance::compute(&t1s, &t2s) / 10.0);

            // Large trees: 10 opp, 5 boards → normalize by 50
            let mut r3 = Xoshiro256PlusPlus::seed_from_u64(deal_rng.gen());
            let mut r4 = Xoshiro256PlusPlus::seed_from_u64(deal_rng.gen());
            let t1l = showdown_distribution_tree(&p1, &board[..3], 0, 10, 5, &mut r3);
            let t2l = showdown_distribution_tree(&p1, &board[..3], 0, 10, 5, &mut r4);
            norm_large.push(rbm_distance::compute(&t1l, &t2l) / 50.0);
        }

        norm_small.sort_by(|a, b| a.partial_cmp(b).unwrap());
        norm_large.sort_by(|a, b| a.partial_cmp(b).unwrap());

        let median_small = norm_small[n_trials / 2];
        let median_large = norm_large[n_trials / 2];
        let mean_small: f64 = norm_small.iter().sum::<f64>() / n_trials as f64;
        let mean_large: f64 = norm_large.iter().sum::<f64>() / n_trials as f64;

        eprintln!("Normalized same-hand noise comparison:");
        eprintln!("  Small (5opp,2bd, /10): median={:.3} mean={:.3}", median_small, mean_small);
        eprintln!("  Large (10opp,5bd, /50): median={:.3} mean={:.3}", median_large, mean_large);

        // Larger trees should have lower normalized noise (better signal)
        assert!(
            mean_large <= mean_small,
            "Larger trees should have lower normalized noise: large={:.3} vs small={:.3}",
            mean_large, mean_small
        );
    }

    #[test]
    fn test_realistic_distance_distribution() {
        // Generate showdown trees for different hands on the same board,
        // measure distances, and verify clustering behavior at epsilon=0.5.
        use crate::rbm_distance;

        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let n_hands = 100;
        let mut trees = Vec::new();

        // Generate trees for many different hands
        for _ in 0..n_hands {
            let (p1, _p2, board) = card::sample_deal(&mut rng);
            let tree = showdown_distribution_tree(
                &p1, &board[..3], 0,
                DEFAULT_MAX_OPPONENTS, DEFAULT_MAX_BOARD_SAMPLES,
                &mut rng,
            );
            trees.push(tree);
        }

        // Compute pairwise distances
        let mut below_0_5 = 0usize;
        let mut below_1_0 = 0usize;
        let mut below_2_0 = 0usize;
        let mut distances = Vec::new();
        let total_pairs = n_hands * (n_hands - 1) / 2;

        for i in 0..n_hands {
            for j in (i+1)..n_hands {
                let d = rbm_distance::compute(&trees[i], &trees[j]);
                distances.push(d);
                if d < 0.5 { below_0_5 += 1; }
                if d < 1.0 { below_1_0 += 1; }
                if d < 2.0 { below_2_0 += 1; }
            }
        }

        distances.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let median_d = distances[distances.len() / 2];
        let mean_d: f64 = distances.iter().sum::<f64>() / distances.len() as f64;

        eprintln!("Realistic distance distribution ({} hands, flop, 10opp/5bd):", n_hands);
        eprintln!("  min={:.3} median={:.3} mean={:.3} max={:.3}",
            distances[0], median_d, mean_d, distances[distances.len() - 1]);
        eprintln!("  < 0.5: {}/{} ({:.1}%)", below_0_5, total_pairs,
            100.0 * below_0_5 as f64 / total_pairs as f64);
        eprintln!("  < 1.0: {}/{} ({:.1}%)", below_1_0, total_pairs,
            100.0 * below_1_0 as f64 / total_pairs as f64);
        eprintln!("  < 2.0: {}/{} ({:.1}%)", below_2_0, total_pairs,
            100.0 * below_2_0 as f64 / total_pairs as f64);

        // Simulate online clustering at epsilon=0.5
        let mut cluster_reps: Vec<&Tree> = Vec::new();
        let mut n_clusters = 0usize;
        for tree in &trees {
            let mut found = false;
            for rep in &cluster_reps {
                let d = rbm_distance::compute(tree, rep);
                if d < 0.5 {
                    found = true;
                    break;
                }
            }
            if !found {
                cluster_reps.push(tree);
                n_clusters += 1;
            }
        }
        eprintln!("  Online clustering eps=0.5: {} clusters from {} hands", n_clusters, n_hands);

        assert!(n_clusters > 0);
    }

    #[test]
    fn test_player_perspective_flip() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let (p1, _p2, board) = card::sample_deal(&mut rng);

        let mut rng0 = Xoshiro256PlusPlus::seed_from_u64(123);
        let mut rng1 = Xoshiro256PlusPlus::seed_from_u64(123);

        let tree0 = showdown_distribution_tree(&p1, &board[..3], 0, 10, 3, &mut rng0);
        let tree1 = showdown_distribution_tree(&p1, &board[..3], 1, 10, 3, &mut rng1);

        // Player 0 and player 1 should have negated EVs for the same hand
        assert!(
            (tree0.ev() + tree1.ev()).abs() < 1e-10,
            "Player 0 EV ({}) and Player 1 EV ({}) should sum to 0",
            tree0.ev(),
            tree1.ev()
        );
    }
}
