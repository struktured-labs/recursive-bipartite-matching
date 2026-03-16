(** 5-card poker hand evaluation for Mini Texas Hold'em.

    Hand rankings (strongest to weakest):
    1. Straight flush (includes royal flush)
    2. Four of a kind
    3. Full house
    4. Flush
    5. Straight (A-2-3-4-5 wraps low)
    6. Three of a kind
    7. Two pair
    8. One pair
    9. High card *)

module Hand_rank : sig
  type t =
    | High_card
    | One_pair
    | Two_pair
    | Three_of_a_kind
    | Straight
    | Flush
    | Full_house
    | Four_of_a_kind
    | Straight_flush
  [@@deriving sexp, compare, equal]

  (** Higher is better *)
  val to_int : t -> int

  val to_string : t -> string
end

(** Evaluate a 5-card hand. Returns (hand_rank, tiebreaker_ranks) where
    tiebreaker_ranks is ordered for lexicographic comparison. *)
val evaluate
  :  Card.t -> Card.t -> Card.t -> Card.t -> Card.t
  -> Hand_rank.t * int list

(** Compare two 5-card hands. Returns positive if hand1 wins,
    negative if hand2 wins, 0 for tie. *)
val compare_hands5
  :  Card.t * Card.t * Card.t * Card.t * Card.t
  -> Card.t * Card.t * Card.t * Card.t * Card.t
  -> int
