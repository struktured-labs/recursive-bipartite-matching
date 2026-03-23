/// Card representation: u8 in 0..51.
/// Encoding: rank_index * 4 + suit_index
/// Matches OCaml's Card.t = int (rank_index * 4 + suit_index).
///
/// rank_index: 0=Two, 1=Three, ..., 12=Ace
/// suit_index: 0=Clubs, 1=Diamonds, 2=Hearts, 3=Spades

pub type Card = u8;

pub const DECK_SIZE: usize = 52;

#[inline(always)]
pub fn rank(c: Card) -> u8 {
    c / 4
}

#[inline(always)]
pub fn suit(c: Card) -> u8 {
    c % 4
}

#[inline(always)]
pub fn create(rank_idx: u8, suit_idx: u8) -> Card {
    rank_idx * 4 + suit_idx
}

/// Sample a deal: 2 hole cards for P1, 2 for P2, 5 board cards.
/// Uses Fisher-Yates partial shuffle on the deck array.
pub fn sample_deal(rng: &mut impl rand::Rng) -> ([Card; 2], [Card; 2], [Card; 5]) {
    let mut deck: [Card; DECK_SIZE] = std::array::from_fn(|i| i as u8);

    // Fisher-Yates partial shuffle for 9 cards
    for i in 0..9 {
        let j = i + (rng.next_u32() as usize % (DECK_SIZE - i));
        deck.swap(i, j);
    }

    let p1 = [deck[0], deck[1]];
    let p2 = [deck[2], deck[3]];
    let board = [deck[4], deck[5], deck[6], deck[7], deck[8]];
    (p1, p2, board)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::SeedableRng;
    use rand_xoshiro::Xoshiro256PlusPlus;

    #[test]
    fn test_card_roundtrip() {
        for r in 0..13u8 {
            for s in 0..4u8 {
                let c = create(r, s);
                assert_eq!(rank(c), r);
                assert_eq!(suit(c), s);
                assert!(c < 52);
            }
        }
    }

    #[test]
    fn test_sample_deal_unique() {
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let (p1, p2, board) = sample_deal(&mut rng);
        let mut all = Vec::new();
        all.extend_from_slice(&p1);
        all.extend_from_slice(&p2);
        all.extend_from_slice(&board);
        all.sort();
        all.dedup();
        assert_eq!(all.len(), 9, "All 9 dealt cards must be unique");
    }
}
