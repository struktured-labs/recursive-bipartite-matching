(** 3-card poker hand evaluation for Rhode Island Hold'em.

    Hand rankings (strongest to weakest):
    1. Three of a kind
    2. Straight (A-2-3 wraps)
    3. Flush
    4. Pair
    5. High card

    Note: In 3-card poker, flushes rank below straights
    (opposite of 5-card poker). *)

module Hand_rank : sig
  type t =
    | High_card
    | Pair
    | Flush
    | Straight
    | Three_of_a_kind
  [@@deriving sexp, compare, equal]

  (** Higher is better *)
  val to_int : t -> int
end

(** Evaluate a 3-card hand. Returns (hand_rank, tiebreaker_ranks) where
    tiebreaker_ranks is sorted for comparison (e.g., pair rank first). *)
val evaluate : Card.t -> Card.t -> Card.t -> Hand_rank.t * int list

(** Compare two 3-card hands. Returns positive if hand1 wins,
    negative if hand2 wins, 0 for tie. *)
val compare_hands
  :  Card.t * Card.t * Card.t
  -> Card.t * Card.t * Card.t
  -> int
