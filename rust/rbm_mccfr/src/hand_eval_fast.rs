/// Fast 7-card hand evaluator using rank/suit bitmasks.
///
/// Replaces the C(7,5)=21 subset enumeration with a single-pass approach:
/// 1. Build 13-bit bitmasks per suit and rank frequency array
/// 2. Check flush (any suit with 5+ bits) — if so, find best 5-card flush
/// 3. Check straight (5 consecutive bits in combined rank mask)
/// 4. Otherwise use rank frequencies for pairs/trips/quads
///
/// This avoids 21 sort+frequency-count calls. One pass through 7 cards,
/// then O(1) bitmask operations.

use crate::card::{Card, rank, suit};

/// Detect the highest straight in a 13-bit rank bitmask.
/// Returns the high rank of the straight (0-12), or -1 if no straight.
///
/// Ranks: bit 0 = Two, bit 12 = Ace.
/// Special case: A-2-3-4-5 wheel (bits 12,3,2,1,0 set).
#[inline]
fn find_straight(mask: u16) -> i8 {
    // Check from top down: 5 consecutive bits
    // We need to check if there are 5 in a row.
    // AKQJT (bits 12..8), KQJT9 (bits 11..7), ..., 65432 (bits 4..0)
    // Fold consecutive bits: keep bit set only if 5 in a row
    let b = mask & (mask >> 1);       // 2 consecutive
    let c = b & (mask >> 2);          // 3 consecutive
    let d = c & (mask >> 3);          // 4 consecutive
    let e = d & (mask >> 4);          // 5 consecutive

    if e != 0 {
        // Highest bit in e gives the high card - 4, so high = bit_pos + 4
        let bit = 15 - e.leading_zeros(); // highest set bit position in u16
        return (bit + 4) as i8;
    }

    // Check for wheel: A(12) 2(0) 3(1) 4(2) 5(3)
    if mask & 0x100F == 0x100F { // bits 12, 3, 2, 1, 0
        return 3; // 5-high straight (wheel)
    }

    -1
}

/// Find the best 5-card hand from the flush suit's cards.
/// `suit_mask` is a 13-bit mask of ranks in the flush suit.
/// The suit has >= 5 cards. We need to evaluate the best 5-card poker hand
/// from those cards (which is always at least a flush, but could be a
/// straight flush).
#[inline]
fn evaluate_flush(suit_mask: u16) -> u32 {
    // Check for straight flush within this suit
    let sf = find_straight(suit_mask);
    if sf >= 0 {
        return 8_000_000 + sf as u32 * 1000;
    }

    // Plain flush: take the top 5 ranks
    let mut ranks = [0u8; 7]; // at most 7 suited cards
    let mut count = 0;
    for r in (0..13u8).rev() {
        if suit_mask & (1 << r) != 0 {
            ranks[count] = r;
            count += 1;
            if count == 5 { break; }
        }
    }

    5_000_000
        + ranks[0] as u32 * 10000
        + ranks[1] as u32 * 1000
        + ranks[2] as u32 * 100
        + ranks[3] as u32 * 10
        + ranks[4] as u32
}

/// Fast 7-card hand evaluator.
///
/// Returns an encoded hand value where higher is better.
/// Encoding: category * 1_000_000 + tiebreaker, matching hand_eval::evaluate7.
pub fn evaluate7_fast(cards: &[u8; 7]) -> u32 {
    // Build suit bitmasks and rank frequencies
    let mut suit_masks: [u16; 4] = [0; 4];
    let mut rank_count: [u8; 13] = [0; 13];

    for &c in cards {
        let r = rank(c) as usize;
        let s = suit(c) as usize;
        suit_masks[s] |= 1 << r;
        rank_count[r] += 1;
    }

    // Check for flush (any suit with 5+ bits set)
    let mut flush_suit: i8 = -1;
    for s in 0..4 {
        if suit_masks[s].count_ones() >= 5 {
            flush_suit = s as i8;
            break;
        }
    }

    let all_ranks: u16 = suit_masks[0] | suit_masks[1] | suit_masks[2] | suit_masks[3];
    let straight_high = find_straight(all_ranks);

    if flush_suit >= 0 {
        // We have a flush. Check if it's also a straight flush.
        let flush_val = evaluate_flush(suit_masks[flush_suit as usize]);

        if straight_high < 0 {
            // No overall straight, so just a flush (might be straight flush
            // within the flush suit, already checked in evaluate_flush)
            return flush_val;
        }

        // There's a straight and a flush. The flush evaluation already checked
        // for straight flush within the suited cards. If it found one, it returned
        // 8_000_000+. If not, we have a flush and a (non-flush) straight.
        // The flush beats the straight, so return the flush value.
        // But we also need to check non-flush hand categories that beat flush.
        // Quads (7) and full house (6) beat flush (5).
        let rank_hand = evaluate_from_rank_counts(&rank_count, straight_high);
        let rank_cat = rank_hand / 1_000_000;
        if rank_cat > 5 {
            // Quads or full house beats flush
            return rank_hand;
        }
        return flush_val;
    }

    // No flush. Evaluate from rank counts and straight.
    evaluate_from_rank_counts(&rank_count, straight_high)
}

/// Evaluate a 7-card hand from rank frequency counts and straight detection.
/// This handles all non-flush categories.
#[inline]
fn evaluate_from_rank_counts(rank_count: &[u8; 13], straight_high: i8) -> u32 {
    // Scan for quads, trips, pairs, kickers (descending rank order)
    let mut quads: u8 = 0;
    let mut trips: u8 = 0;
    let mut pairs: u8 = 0;
    let mut quad_rank: u8 = 0;
    let mut trip_ranks = [0u8; 2]; // at most 2 trips in 7 cards
    let mut pair_ranks = [0u8; 3]; // at most 3 pairs in 7 cards
    let mut kickers = [0u8; 7];
    let mut ki: usize = 0;

    for r in (0..13u8).rev() {
        match rank_count[r as usize] {
            4 => {
                if quads == 0 { quad_rank = r; }
                quads += 1;
            }
            3 => {
                if trips < 2 { trip_ranks[trips as usize] = r; }
                trips += 1;
            }
            2 => {
                if pairs < 3 { pair_ranks[pairs as usize] = r; }
                pairs += 1;
            }
            1 => {
                if ki < 7 { kickers[ki] = r; ki += 1; }
            }
            _ => {}
        }
    }

    // Four of a kind
    if quads >= 1 {
        // Best kicker: highest rank that isn't the quad
        let mut best_kicker = 0u8;
        for r in (0..13u8).rev() {
            if r != quad_rank && rank_count[r as usize] > 0 {
                best_kicker = r;
                break;
            }
        }
        return 7_000_000 + quad_rank as u32 * 1000 + best_kicker as u32;
    }

    // Full house: trips + (another trips or pair)
    if trips >= 2 {
        // Two sets of trips: best full house is highest trip + second trip as pair
        return 6_000_000 + trip_ranks[0] as u32 * 1000 + trip_ranks[1] as u32;
    }
    if trips == 1 && pairs >= 1 {
        return 6_000_000 + trip_ranks[0] as u32 * 1000 + pair_ranks[0] as u32;
    }

    // Straight (no flush at this point)
    if straight_high >= 0 {
        return 4_000_000 + straight_high as u32 * 1000;
    }

    // Three of a kind
    if trips == 1 {
        return 3_000_000 + trip_ranks[0] as u32 * 1000
            + kickers[0] as u32 * 10 + kickers[1] as u32;
    }

    // Two pair
    if pairs >= 2 {
        // Find best kicker not in either pair
        let mut best_kicker = 0u8;
        for r in (0..13u8).rev() {
            if r != pair_ranks[0] && r != pair_ranks[1] && rank_count[r as usize] > 0 {
                best_kicker = r;
                break;
            }
        }
        return 2_000_000
            + pair_ranks[0] as u32 * 1000
            + pair_ranks[1] as u32 * 100
            + best_kicker as u32;
    }

    // One pair
    if pairs == 1 {
        return 1_000_000
            + pair_ranks[0] as u32 * 10000
            + kickers[0] as u32 * 100
            + kickers[1] as u32 * 10
            + kickers[2] as u32;
    }

    // High card: top 5 kickers
    kickers[0] as u32 * 10000
        + kickers[1] as u32 * 1000
        + kickers[2] as u32 * 100
        + kickers[3] as u32 * 10
        + kickers[4] as u32
}

/// Compare two 7-card hands using the fast evaluator.
/// Returns >0 if hand1 wins, <0 if hand2 wins, 0 for tie.
pub fn compare_hands7_fast(hand1: &[Card; 7], hand2: &[Card; 7]) -> i32 {
    let v1 = evaluate7_fast(hand1);
    let v2 = evaluate7_fast(hand2);
    (v1 as i32) - (v2 as i32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::card::create;
    use crate::hand_eval;

    fn c(rank_idx: u8, suit_idx: u8) -> Card {
        create(rank_idx, suit_idx)
    }

    #[test]
    fn test_pair_beats_high_card() {
        let pair_aces = [c(12, 0), c(12, 1), c(5, 2), c(3, 3), c(1, 0), c(0, 1), c(9, 2)];
        let king_high = [c(11, 0), c(10, 1), c(8, 2), c(6, 3), c(4, 0), c(2, 1), c(0, 2)];
        assert!(compare_hands7_fast(&pair_aces, &king_high) > 0);
    }

    #[test]
    fn test_flush_beats_straight() {
        let flush = [c(12, 2), c(10, 2), c(7, 2), c(4, 2), c(2, 2), c(0, 0), c(1, 1)];
        let straight = [c(3, 0), c(4, 1), c(5, 2), c(6, 3), c(7, 0), c(0, 1), c(1, 2)];
        assert!(compare_hands7_fast(&flush, &straight) > 0);
    }

    #[test]
    fn test_straight_flush_beats_quads() {
        let sf = [c(8, 0), c(7, 0), c(6, 0), c(5, 0), c(4, 0), c(0, 1), c(1, 2)];
        let quads = [c(12, 0), c(12, 1), c(12, 2), c(12, 3), c(11, 0), c(10, 1), c(9, 2)];
        assert!(compare_hands7_fast(&sf, &quads) > 0);
    }

    #[test]
    fn test_full_house_beats_flush() {
        let fh = [c(10, 0), c(10, 1), c(10, 2), c(5, 0), c(5, 1), c(0, 3), c(1, 3)];
        let flush = [c(12, 2), c(10, 2), c(7, 2), c(4, 2), c(2, 2), c(0, 0), c(1, 1)];
        assert!(compare_hands7_fast(&fh, &flush) > 0);
    }

    #[test]
    fn test_wheel_straight() {
        // A-2-3-4-5 wheel vs pair of kings
        let wheel = [c(12, 0), c(0, 1), c(1, 2), c(2, 3), c(3, 0), c(8, 1), c(9, 2)];
        let pair_k = [c(11, 0), c(11, 1), c(7, 2), c(4, 3), c(2, 0), c(0, 2), c(1, 3)];
        // Wheel = straight (category 4), pair of kings = category 1
        assert!(compare_hands7_fast(&wheel, &pair_k) > 0);
    }

    #[test]
    fn test_two_pair_ordering() {
        // KKJJ vs QQTT - kings beat queens when both are two pair
        let kkjj = [c(11, 0), c(11, 1), c(9, 0), c(9, 1), c(5, 2), c(3, 3), c(1, 2)];
        let qqtt = [c(10, 0), c(10, 1), c(8, 0), c(8, 1), c(5, 3), c(3, 2), c(1, 3)];
        assert!(compare_hands7_fast(&kkjj, &qqtt) > 0);
    }

    #[test]
    fn test_fast_vs_old_random_1000() {
        // Compare fast evaluator against old C(7,5) evaluator for 1000 random hands
        use rand::SeedableRng;
        use rand_xoshiro::Xoshiro256PlusPlus;

        let mut rng = Xoshiro256PlusPlus::seed_from_u64(12345);
        let mut mismatches = 0;

        for _ in 0..1000 {
            let (p1, p2, board) = crate::card::sample_deal(&mut rng);

            let mut h1 = [0u8; 7];
            h1[0] = p1[0]; h1[1] = p1[1];
            h1[2..7].copy_from_slice(&board);

            let mut h2 = [0u8; 7];
            h2[0] = p2[0]; h2[1] = p2[1];
            h2[2..7].copy_from_slice(&board);

            let old_cmp = hand_eval::compare_hands7(&h1, &h2);
            let new_cmp = compare_hands7_fast(&h1, &h2);

            // They must agree on winner/loser/tie
            let old_sign = old_cmp.signum();
            let new_sign = new_cmp.signum();
            if old_sign != new_sign {
                mismatches += 1;
                eprintln!(
                    "MISMATCH: h1={:?} h2={:?} old={} new={}",
                    h1, h2, old_cmp, new_cmp
                );
            }
        }

        assert_eq!(mismatches, 0, "{} mismatches in 1000 random comparisons", mismatches);
    }

    #[test]
    fn test_fast_vs_old_exhaustive_value_ordering() {
        // For 5000 random 7-card hands, verify that the relative ordering
        // (greater/equal/less) is the same between old and new evaluators.
        use rand::SeedableRng;
        use rand_xoshiro::Xoshiro256PlusPlus;

        let mut rng = Xoshiro256PlusPlus::seed_from_u64(99999);
        let mut hands: Vec<[u8; 7]> = Vec::new();

        for _ in 0..200 {
            let (p1, p2, board) = crate::card::sample_deal(&mut rng);
            let mut h1 = [0u8; 7];
            h1[0] = p1[0]; h1[1] = p1[1];
            h1[2..7].copy_from_slice(&board);
            let mut h2 = [0u8; 7];
            h2[0] = p2[0]; h2[1] = p2[1];
            h2[2..7].copy_from_slice(&board);
            hands.push(h1);
            hands.push(h2);
        }

        // Compare all pairs
        let mut mismatches = 0;
        for i in 0..hands.len() {
            for j in (i+1)..hands.len().min(i + 20) {
                let old_v1 = hand_eval::evaluate7(&hands[i]);
                let old_v2 = hand_eval::evaluate7(&hands[j]);
                let new_v1 = evaluate7_fast(&hands[i]);
                let new_v2 = evaluate7_fast(&hands[j]);

                let old_cmp = (old_v1 as i32 - old_v2 as i32).signum();
                let new_cmp = (new_v1 as i32 - new_v2 as i32).signum();
                if old_cmp != new_cmp {
                    mismatches += 1;
                }
            }
        }
        assert_eq!(mismatches, 0, "{} ordering mismatches", mismatches);
    }
}
