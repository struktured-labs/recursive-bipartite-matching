/// Equity-based bucket computation.
///
/// Preflop: maps hole cards to a canonical hand ID (0-168) and looks up a
/// precomputed bucket assignment.
/// Post-flop: evaluates the player's best hand from available cards, normalizes
/// the score to [0, 1], and quantizes to a bucket index.
///
/// Ported from OCaml's compact_cfr.ml `hand_score` / `compute_bucket_equity`.

use crate::card::{self, Card};
use crate::hand_eval_fast;

/// Canonical hand ID for a pair of hole cards. There are 169 canonical hands:
///   - 13 pocket pairs (AA, KK, ..., 22)
///   - 78 suited combos (AKs, AQs, ..., 32s)
///   - 78 offsuit combos (AKo, AQo, ..., 32o)
///
/// Ordering matches OCaml's Equity.all_canonical_hands: iterate r1 >= r2,
/// pocket pair first, then suited, then offsuit.
pub fn canonical_hand_id(c1: Card, c2: Card) -> usize {
    let r1 = card::rank(c1);
    let r2 = card::rank(c2);
    let s1 = card::suit(c1);
    let s2 = card::suit(c2);

    // Ensure high_rank >= low_rank
    let (high_rank, low_rank) = if r1 >= r2 { (r1, r2) } else { (r2, r1) };
    let suited = s1 == s2;

    // For pairs, suited is always false in canonical form
    let is_pair = high_rank == low_rank;

    // Compute ID using same iteration order as OCaml:
    //   for r1 in 0..13: for r2 in 0..=r1:
    //     if r1 == r2: emit pair (1 hand)
    //     else: emit suited (1 hand), offsuit (1 hand)
    let mut id = 0usize;
    for ri in 0..13u8 {
        for rj in 0..=ri {
            if ri == high_rank && rj == low_rank {
                if is_pair {
                    return id;
                } else if suited {
                    return id; // suited comes first after pair
                } else {
                    return id + 1; // offsuit comes second
                }
            }
            if ri == rj {
                id += 1; // pair
            } else {
                id += 2; // suited + offsuit
            }
        }
    }
    // Should never reach here for valid cards
    0
}

/// Hand score for post-flop bucketing. Given hole cards and visible board
/// cards, evaluates the best 5-card hand and returns a score in [0, 1).
///
/// This matches OCaml's hand_score: the evaluate7/evaluate5 result is
/// decomposed into a category (0-8) and tiebreaker, yielding:
///   rank_score = category / 9.0
///   tb_score = first_tiebreaker / 150.0
///   score = min(0.999, rank_score + tb_score * 0.1)
///
/// For the Rust evaluate7/evaluate5, the encoded value is:
///   category * 1_000_000 + sub-rank encoding
/// We extract the category and leading tiebreaker from the encoding.
pub fn hand_score(hole_cards: &[Card; 2], board_visible: &[Card]) -> f64 {
    let n = 2 + board_visible.len();
    let eval_value = match n {
        7 => {
            let mut cards = [0u8; 7];
            cards[0] = hole_cards[0];
            cards[1] = hole_cards[1];
            cards[2..7].copy_from_slice(&board_visible[..5]);
            hand_eval_fast::evaluate7_fast(&cards)
        }
        6 => {
            // Best of 6 choose 5 = 6 five-card subsets
            let mut all_cards = [0u8; 6];
            all_cards[0] = hole_cards[0];
            all_cards[1] = hole_cards[1];
            all_cards[2..6].copy_from_slice(&board_visible[..4]);
            let mut best = 0u32;
            for skip in 0..6 {
                let mut hand = [0u8; 7];
                let mut k = 0usize;
                for (i, &c) in all_cards.iter().enumerate() {
                    if i != skip {
                        hand[k] = c;
                        k += 1;
                    }
                }
                // Pad remaining slots with card 0 placeholders — evaluate5
                // only looks at the first 5 elements but we need a [u8; 7]
                // shaped array. Instead, call our evaluate5 via evaluate7's
                // inner logic. Actually, we can just evaluate the 5-card
                // hand directly using evaluate7 by duplicating two cards.
                // Safer: inline evaluate5.
                let val = evaluate5_from_slice(&hand[..5]);
                if val > best {
                    best = val;
                }
            }
            best
        }
        5 => {
            let mut all_cards = [0u8; 5];
            all_cards[0] = hole_cards[0];
            all_cards[1] = hole_cards[1];
            all_cards[2..5].copy_from_slice(&board_visible[..3]);
            evaluate5_from_slice(&all_cards)
        }
        _ => 0,
    };

    // Decompose evaluate value into category and tiebreaker.
    // Our hand_eval encodes as: category * 1_000_000 + sub_encoding.
    // The OCaml scoring: rank_score = category/9.0, tb_score = first_tb/150.0,
    //   final = min(0.999, rank_score + tb_score * 0.1)
    //
    // We extract category and an approximate leading tiebreaker.
    let category = eval_value / 1_000_000;
    let sub = eval_value % 1_000_000;

    // Extract leading tiebreaker: for most categories, the primary rank
    // component is encoded in the thousands digit or leading positions.
    // A rough proxy: use sub / 1000 as the tiebreaker rank (0-12 range,
    // sometimes up to ~120 for flush encoding, but /150 clamps it).
    let first_tb = match category {
        5 => sub / 10000,  // Flush: leading rank encoded in 10000s
        _ => sub / 1000,   // Most others: leading rank in 1000s
    };

    let rank_score = category as f64 / 9.0;
    let tb_score = first_tb as f64 / 150.0;
    (rank_score + tb_score * 0.1).min(0.999)
}

/// Evaluate a 5-card hand from a slice. Reuses the same logic as hand_eval's
/// evaluate5 but works with slices instead of fixed arrays.
fn evaluate5_from_slice(cards: &[u8]) -> u32 {
    debug_assert!(cards.len() >= 5);
    let arr: [Card; 5] = [cards[0], cards[1], cards[2], cards[3], cards[4]];
    // Use the evaluate7 path with padding — actually we need the 5-card
    // evaluator. Since hand_eval only exposes evaluate7 publicly, we replicate
    // the key logic here. For correctness, wrap the 5 cards into a 7-card
    // array by duplicating two cards and use evaluate7 (which finds the best
    // 5-card subset, which will be the original 5).
    //
    // Actually evaluate7 picks best of C(7,5)=21 subsets, so duplicating
    // cards would find the same 5-card hand. But duplicates could affect
    // pair/trips counting. Instead, just call evaluate7 with 5 unique cards
    // padded by two "phantom" cards that can't improve the hand.
    //
    // Simplest correct approach: expose evaluate5 or inline it.
    // Let's inline a minimal evaluate5.
    evaluate5_inline(&arr)
}

/// Inline 5-card hand evaluator (same logic as hand_eval::evaluate5 but
/// accessible from this module).
fn evaluate5_inline(cards: &[Card; 5]) -> u32 {
    let mut ranks: [u8; 5] = std::array::from_fn(|i| card::rank(cards[i]));
    let suits: [u8; 5] = std::array::from_fn(|i| card::suit(cards[i]));

    ranks.sort_unstable();
    ranks.reverse();

    let is_flush = suits[0] == suits[1]
        && suits[1] == suits[2]
        && suits[2] == suits[3]
        && suits[3] == suits[4];

    let is_straight = (ranks[0] - ranks[4] == 4
        && ranks[0] != ranks[1]
        && ranks[1] != ranks[2]
        && ranks[2] != ranks[3]
        && ranks[3] != ranks[4])
        || (ranks[0] == 12 && ranks[1] == 3 && ranks[2] == 2 && ranks[3] == 1 && ranks[4] == 0);

    let straight_high = if ranks[0] == 12 && ranks[1] == 3 {
        3u8
    } else {
        ranks[0]
    };

    let mut freq = [0u8; 13];
    for &r in &ranks {
        freq[r as usize] += 1;
    }

    let mut quads = 0u8;
    let mut trips = 0u8;
    let mut pairs = 0u8;
    let mut quad_rank = 0u8;
    let mut trip_rank = 0u8;
    let mut pair_ranks = [0u8; 2];
    let mut kickers = [0u8; 5];
    let mut ki = 0usize;

    for r in (0..13u8).rev() {
        match freq[r as usize] {
            4 => { quads += 1; quad_rank = r; }
            3 => { trips += 1; trip_rank = r; }
            2 => {
                if pairs < 2 { pair_ranks[pairs as usize] = r; }
                pairs += 1;
            }
            1 => {
                if ki < 5 { kickers[ki] = r; ki += 1; }
            }
            _ => {}
        }
    }

    if is_straight && is_flush {
        8_000_000 + straight_high as u32 * 1000
    } else if quads >= 1 {
        7_000_000 + quad_rank as u32 * 1000 + kickers[0] as u32
    } else if trips >= 1 && pairs >= 1 {
        6_000_000 + trip_rank as u32 * 1000 + pair_ranks[0] as u32
    } else if is_flush {
        5_000_000
            + ranks[0] as u32 * 10000
            + ranks[1] as u32 * 1000
            + ranks[2] as u32 * 100
            + ranks[3] as u32 * 10
            + ranks[4] as u32
    } else if is_straight {
        4_000_000 + straight_high as u32 * 1000
    } else if trips >= 1 {
        3_000_000 + trip_rank as u32 * 1000 + kickers[0] as u32 * 10 + kickers[1] as u32
    } else if pairs >= 2 {
        2_000_000
            + pair_ranks[0] as u32 * 1000
            + pair_ranks[1] as u32 * 100
            + kickers[0] as u32
    } else if pairs == 1 {
        1_000_000
            + pair_ranks[0] as u32 * 10000
            + kickers[0] as u32 * 100
            + kickers[1] as u32 * 10
            + kickers[2] as u32
    } else {
        ranks[0] as u32 * 10000
            + ranks[1] as u32 * 1000
            + ranks[2] as u32 * 100
            + ranks[3] as u32 * 10
            + ranks[4] as u32
    }
}

/// Precompute bucket assignments for all 4 streets of a single deal.
///
/// - Round 0 (preflop): uses the canonical hand ID → preflop_assignments lookup
/// - Round 1 (flop): hand_score with hole + board[0..3]
/// - Round 2 (turn): hand_score with hole + board[0..4]
/// - Round 3 (river): hand_score with hole + board[0..5]
pub fn precompute_buckets(
    hole_cards: &[Card; 2],
    board: &[Card; 5],
    n_buckets: u32,
    preflop_assignments: &[i32; 169],
) -> [u32; 4] {
    let mut buckets = [0u32; 4];

    // Round 0: preflop
    let cid = canonical_hand_id(hole_cards[0], hole_cards[1]);
    let preflop_bucket = preflop_assignments[cid];
    buckets[0] = if preflop_bucket >= 0 {
        preflop_bucket as u32
    } else {
        0
    };

    // Round 1: flop (hole + 3 board cards)
    let flop_score = hand_score(hole_cards, &board[..3]);
    buckets[1] = ((flop_score * n_buckets as f64) as u32).min(n_buckets - 1);

    // Round 2: turn (hole + 4 board cards)
    let turn_score = hand_score(hole_cards, &board[..4]);
    buckets[2] = ((turn_score * n_buckets as f64) as u32).min(n_buckets - 1);

    // Round 3: river (hole + 5 board cards)
    let river_score = hand_score(hole_cards, &board[..5]);
    buckets[3] = ((river_score * n_buckets as f64) as u32).min(n_buckets - 1);

    buckets
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::card::create;

    #[test]
    fn test_canonical_hand_id_range() {
        // All 52*51/2 = 1326 two-card combos should map to 0..169
        let mut seen = [false; 169];
        for c1 in 0..52u8 {
            for c2 in (c1 + 1)..52u8 {
                let id = canonical_hand_id(c1, c2);
                assert!(id < 169, "canonical_hand_id({}, {}) = {} out of range", c1, c2, id);
                seen[id] = true;
            }
        }
        // All 169 canonical hands should be reachable
        for (i, &s) in seen.iter().enumerate() {
            assert!(s, "canonical hand {} not reachable", i);
        }
    }

    #[test]
    fn test_canonical_hand_id_pair() {
        // AA: rank 12, same rank → pocket pair
        let c1 = create(12, 0); // Ac
        let c2 = create(12, 1); // Ad
        let id1 = canonical_hand_id(c1, c2);

        // AA suited or offsuit doesn't matter for pairs
        let c3 = create(12, 2); // Ah
        let id2 = canonical_hand_id(c1, c3);
        assert_eq!(id1, id2, "All AA combos should map to same canonical ID");
    }

    #[test]
    fn test_canonical_hand_id_suited_vs_offsuit() {
        // AKs vs AKo should differ
        let aks = canonical_hand_id(create(12, 0), create(11, 0)); // same suit
        let ako = canonical_hand_id(create(12, 0), create(11, 1)); // different suit
        assert_ne!(aks, ako, "AKs and AKo should have different canonical IDs");
        // Suited should come before offsuit (lower ID)
        assert!(aks < ako, "AKs ({}) should come before AKo ({})", aks, ako);
    }

    #[test]
    fn test_canonical_hand_id_symmetric() {
        // canonical_hand_id(c1, c2) == canonical_hand_id(c2, c1)
        for c1 in 0..52u8 {
            for c2 in (c1 + 1)..52u8 {
                assert_eq!(
                    canonical_hand_id(c1, c2),
                    canonical_hand_id(c2, c1),
                    "canonical_hand_id should be symmetric for {} and {}",
                    c1, c2,
                );
            }
        }
    }

    #[test]
    fn test_hand_score_range() {
        // Hand score should always be in [0, 1)
        use rand::SeedableRng;
        use rand_xoshiro::Xoshiro256PlusPlus;
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        for _ in 0..1000 {
            let (p1, _p2, board) = crate::card::sample_deal(&mut rng);
            // Flop
            let s1 = hand_score(&p1, &board[..3]);
            assert!(s1 >= 0.0 && s1 < 1.0, "flop score out of range: {}", s1);
            // Turn
            let s2 = hand_score(&p1, &board[..4]);
            assert!(s2 >= 0.0 && s2 < 1.0, "turn score out of range: {}", s2);
            // River
            let s3 = hand_score(&p1, &board[..5]);
            assert!(s3 >= 0.0 && s3 < 1.0, "river score out of range: {}", s3);
        }
    }

    #[test]
    fn test_hand_score_ordering() {
        // Flush should score higher than high card
        let flush_hole = [create(12, 2), create(10, 2)]; // Ah, Th
        let flush_board = [create(7, 2), create(4, 2), create(2, 2)]; // 9h, 6h, 4h
        let flush_score = hand_score(&flush_hole, &flush_board);

        let high_hole = [create(11, 0), create(9, 1)]; // Kc, Jd
        let high_board = [create(6, 2), create(3, 3), create(1, 0)]; // 8h, 5s, 3c
        let high_score = hand_score(&high_hole, &high_board);

        assert!(flush_score > high_score,
            "flush ({}) should score higher than high card ({})",
            flush_score, high_score);
    }

    #[test]
    fn test_precompute_buckets_valid() {
        use rand::SeedableRng;
        use rand_xoshiro::Xoshiro256PlusPlus;
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(99);

        // Simple uniform preflop assignments
        let n_buckets = 50u32;
        let mut assignments = [0i32; 169];
        for (i, a) in assignments.iter_mut().enumerate() {
            *a = (i as i32) % n_buckets as i32;
        }

        for _ in 0..500 {
            let (p1, _p2, board) = crate::card::sample_deal(&mut rng);
            let buckets = precompute_buckets(&p1, &board, n_buckets, &assignments);
            for (round, &b) in buckets.iter().enumerate() {
                assert!(b < n_buckets,
                    "bucket[{}] = {} >= n_buckets={}", round, b, n_buckets);
            }
        }
    }
}
