/// 7-card hand evaluation for Hold'em showdown.
///
/// For Phase 1: enumerate all C(7,5)=21 five-card subsets and evaluate each.
/// Phase 2 will replace this with a Two Plus Two lookup table (50x faster).
///
/// Hand rankings (higher = better):
///   8: Straight flush
///   7: Four of a kind
///   6: Full house
///   5: Flush
///   4: Straight
///   3: Three of a kind
///   2: Two pair
///   1: One pair
///   0: High card

use crate::card::{Card, rank, suit};

/// Evaluate a 5-card hand. Returns (category, tiebreaker) where higher is better.
/// Category is 0-8, tiebreaker differentiates within category.
fn evaluate5(cards: &[Card; 5]) -> u32 {
    let mut ranks: [u8; 5] = std::array::from_fn(|i| rank(cards[i]));
    let suits: [u8; 5] = std::array::from_fn(|i| suit(cards[i]));

    ranks.sort_unstable();
    ranks.reverse(); // Descending

    let is_flush = suits[0] == suits[1]
        && suits[1] == suits[2]
        && suits[2] == suits[3]
        && suits[3] == suits[4];

    // Check for straight (including A-2-3-4-5 wheel)
    let is_straight = (ranks[0] - ranks[4] == 4
        && ranks[0] != ranks[1]
        && ranks[1] != ranks[2]
        && ranks[2] != ranks[3])
        || (ranks[0] == 12 && ranks[1] == 3 && ranks[2] == 2 && ranks[3] == 1 && ranks[4] == 0);

    // Wheel adjustment: A-2-3-4-5 → high card is 3 (the 5)
    let straight_high = if ranks[0] == 12 && ranks[1] == 3 {
        3u8 // wheel
    } else {
        ranks[0]
    };

    // Count rank frequencies
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
            4 => {
                quads += 1;
                quad_rank = r;
            }
            3 => {
                trips += 1;
                trip_rank = r;
            }
            2 => {
                if pairs < 2 {
                    pair_ranks[pairs as usize] = r;
                }
                pairs += 1;
            }
            1 => {
                if ki < 5 {
                    kickers[ki] = r;
                    ki += 1;
                }
            }
            _ => {}
        }
    }

    // Encode: category * 1_000_000 + tiebreaker
    if is_straight && is_flush {
        // Straight flush
        8_000_000 + straight_high as u32 * 1000
    } else if quads >= 1 {
        // Four of a kind
        7_000_000 + quad_rank as u32 * 1000 + kickers[0] as u32
    } else if trips >= 1 && pairs >= 1 {
        // Full house
        6_000_000 + trip_rank as u32 * 1000 + pair_ranks[0] as u32
    } else if is_flush {
        // Flush
        5_000_000
            + ranks[0] as u32 * 10000
            + ranks[1] as u32 * 1000
            + ranks[2] as u32 * 100
            + ranks[3] as u32 * 10
            + ranks[4] as u32
    } else if is_straight {
        // Straight
        4_000_000 + straight_high as u32 * 1000
    } else if trips >= 1 {
        // Three of a kind
        3_000_000 + trip_rank as u32 * 1000 + kickers[0] as u32 * 10 + kickers[1] as u32
    } else if pairs >= 2 {
        // Two pair
        2_000_000
            + pair_ranks[0] as u32 * 1000
            + pair_ranks[1] as u32 * 100
            + kickers[0] as u32
    } else if pairs == 1 {
        // One pair
        1_000_000
            + pair_ranks[0] as u32 * 10000
            + kickers[0] as u32 * 100
            + kickers[1] as u32 * 10
            + kickers[2] as u32
    } else {
        // High card
        ranks[0] as u32 * 10000
            + ranks[1] as u32 * 1000
            + ranks[2] as u32 * 100
            + ranks[3] as u32 * 10
            + ranks[4] as u32
    }
}

/// Evaluate best 5-card hand from 7 cards (enumerate all C(7,5)=21 subsets).
pub fn evaluate7(cards: &[Card; 7]) -> u32 {
    let mut best = 0u32;
    // Enumerate all 21 five-card subsets
    for i in 0..7 {
        for j in (i + 1)..7 {
            // Skip cards i and j
            let mut hand = [0u8; 5];
            let mut k = 0;
            for c in 0..7 {
                if c != i && c != j {
                    hand[k] = cards[c];
                    k += 1;
                }
            }
            let val = evaluate5(&hand);
            if val > best {
                best = val;
            }
        }
    }
    best
}

/// Compare two 7-card hands. Returns >0 if hand1 wins, <0 if hand2 wins, 0 for tie.
pub fn compare_hands7(hand1: &[Card; 7], hand2: &[Card; 7]) -> i32 {
    let v1 = evaluate7(hand1);
    let v2 = evaluate7(hand2);
    (v1 as i32) - (v2 as i32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::card::create;

    fn c(rank_idx: u8, suit_idx: u8) -> Card {
        create(rank_idx, suit_idx)
    }

    #[test]
    fn test_pair_beats_high_card() {
        // Pair of aces vs king high
        let pair_aces = [c(12, 0), c(12, 1), c(5, 2), c(3, 3), c(1, 0), c(0, 1), c(9, 2)];
        let king_high = [c(11, 0), c(10, 1), c(8, 2), c(6, 3), c(4, 0), c(2, 1), c(0, 2)];
        assert!(compare_hands7(&pair_aces, &king_high) > 0);
    }

    #[test]
    fn test_flush_beats_straight() {
        // Flush (all hearts)
        let flush = [c(12, 2), c(10, 2), c(7, 2), c(4, 2), c(2, 2), c(0, 0), c(1, 1)];
        // Straight (5-6-7-8-9)
        let straight = [c(3, 0), c(4, 1), c(5, 2), c(6, 3), c(7, 0), c(0, 1), c(1, 2)];
        assert!(compare_hands7(&flush, &straight) > 0);
    }
}
