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
    /// Cache: (hole_card_key, board_visible_key, round_idx) -> cluster_id.
    /// Prevents the same (hand, board) from getting different cluster IDs
    /// due to MC noise in showdown_distribution_tree.
    pub cache: rustc_hash::FxHashMap<u64, u32>,
}

impl PostflopState {
    /// Create a new empty post-flop state.
    pub fn new() -> Self {
        PostflopState {
            clusters: [Vec::new(), Vec::new(), Vec::new()],
            cache: rustc_hash::FxHashMap::default(),
        }
    }

    /// Get total cluster count across all streets.
    pub fn total_clusters(&self) -> usize {
        self.clusters.iter().map(|c| c.len()).sum()
    }

    /// Compute a cache key from hole cards + visible board + round.
    fn cache_key(hole_cards: &[Card; 2], board_visible: &[Card], round_idx: u8) -> u64 {
        // Pack cards into a u64: each card is 6 bits (0-51), round is 2 bits
        let mut key: u64 = 0;
        key = key.wrapping_mul(53).wrapping_add(hole_cards[0] as u64);
        key = key.wrapping_mul(53).wrapping_add(hole_cards[1] as u64);
        for &c in board_visible {
            key = key.wrapping_mul(53).wrapping_add(c as u64);
        }
        key = key.wrapping_mul(4).wrapping_add(round_idx as u64);
        key
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
/// Returns `Some((cluster_index, distance))` if a cluster within epsilon exists,
/// or `None` if the cluster list is empty.
///
/// Matches OCaml's `find_nearest_postflop_cluster`.
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
        // EV pre-filter: skip clusters where EV difference alone exceeds epsilon
        let ev_diff = (tree_ev - cluster.rep_ev).abs();
        if ev_diff > epsilon {
            continue;
        }
        // Also skip if EV diff already worse than our best so far
        if ev_diff >= best_dist {
            continue;
        }

        // Progressive RBM distance with early-out at threshold=epsilon
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
/// Builds a showdown distribution tree for the hand, then finds or creates
/// a cluster for it.
///
/// Returns the bucket index (cluster index for this street).
///
/// Matches OCaml's `compute_bucket_rbm_postflop`.
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

    // Cache lookup: same (hand, board_visible, round) always returns same cluster.
    // This prevents MC noise from creating different cluster IDs for the same situation.
    let cache_key = PostflopState::cache_key(hole_cards, board_visible, round_idx);
    if let Some(&cached_bucket) = postflop.cache.get(&cache_key) {
        return cached_bucket;
    }

    // Build showdown distribution tree for this hand+board
    let tree = showdown_distribution_tree(
        hole_cards,
        board_visible,
        player,
        5,  // max_opponents
        2,  // max_board_samples
        rng,
    );

    // Map round_idx to cluster array index (round 1->0, 2->1, 3->2)
    let street_idx = (round_idx - 1) as usize;
    debug_assert!(street_idx < 3, "Invalid street index: {}", street_idx);

    let clusters = &postflop.clusters[street_idx];
    let nearest = find_nearest_postflop_cluster(clusters, &tree, epsilon, rbm_config);

    let bucket = match nearest {
        Some((idx, d)) => {
            if d < epsilon {
                // Assign to existing cluster
                postflop.clusters[street_idx][idx].member_count += 1;
                idx as u32
            } else {
                // Create new cluster
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
            // First cluster for this street
            let new_cluster = PostflopCluster {
                rep_ev: tree.ev(),
                representative: tree,
                member_count: 1,
            };
            postflop.clusters[street_idx].push(new_cluster);
            0
        }
    };

    // Cache the assignment for deterministic future lookups
    postflop.cache.insert(cache_key, bucket);
    bucket
}

/// Precompute all 4 street buckets for a deal using RBM.
///
/// - Round 0 (preflop): uses the canonical hand ID -> preflop_assignments lookup
///   (same as equity bucketing for preflop).
/// - Rounds 1-3 (flop/turn/river): uses RBM-based clustering.
///
/// Matches OCaml's `precompute_buckets_rbm`.
pub fn precompute_buckets_rbm(
    hole_cards: &[Card; 2],
    board: &[Card; 5],
    preflop_assignments: &[i32; 169],
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

    // Rounds 1-3: RBM-based post-flop bucketing
    for round_idx in 1..=3u8 {
        result[round_idx as usize] = compute_bucket_rbm_postflop(
            hole_cards,
            board,
            round_idx,
            0, // player — bucket computation is from player 0's perspective
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
    fn test_identical_hands_same_cluster() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let (p1, _p2, board) = card::sample_deal(&mut rng);
        let rbm_config = RbmConfig::default();
        let mut postflop = PostflopState::new();

        // Assign same hand twice -- with high epsilon, should get same cluster
        let b1 = compute_bucket_rbm_postflop(
            &p1, &board, 1, 0, 10.0, &rbm_config, &mut postflop, &mut rng,
        );
        let b2 = compute_bucket_rbm_postflop(
            &p1, &board, 1, 0, 10.0, &rbm_config, &mut postflop, &mut rng,
        );
        // Note: b1 and b2 may differ because the trees are MC sampled, but
        // with high epsilon they should usually match
        assert_eq!(
            postflop.clusters[0].len(),
            1,
            "With high epsilon, same hand should create only 1 cluster, got {}",
            postflop.clusters[0].len()
        );
        assert_eq!(b1, b2);
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
            0.5,
            &rbm_config,
            &mut postflop,
            &mut rng,
        );

        // Should return 4 bucket values
        assert!(
            buckets[0] < 50,
            "Preflop bucket should be < 50, got {}",
            buckets[0]
        );
        // Post-flop buckets are cluster indices (0-based)
        for round in 1..4 {
            // Just verify they don't panic and return some value
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
                0.05, // very tight epsilon -> many clusters
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
                0.05,
                &rbm_config,
                &mut postflop_tight,
                &mut rng_tight,
            );
            precompute_buckets_rbm(
                &p1_l,
                &board_l,
                &assignments,
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
