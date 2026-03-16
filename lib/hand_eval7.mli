(** 7-card poker hand evaluation (best 5 of 7).

    Enumerates all C(7,5) = 21 five-card subsets, evaluates each with
    Hand_eval5, and returns the best hand.  Used for full Texas Hold'em
    and Limit Hold'em showdowns (2 hole cards + 5 community cards). *)

(** Evaluate the best 5-card hand from exactly 7 cards.
    Returns (hand_rank, tiebreaker_ranks) for the strongest subset. *)
val evaluate7 : Card.t list -> Hand_eval5.Hand_rank.t * int list

(** Compare two 7-card hands.  Returns positive if hand1 wins,
    negative if hand2 wins, 0 for a tie. *)
val compare_hands7 : Card.t list -> Card.t list -> int
