(** Suit isomorphism for 2-card starting hands in Texas Hold'em.

    Maps any 2-card hand to one of 169 canonical starting hand classes:
    - 13 pocket pairs   (AA, KK, ..., 22)
    - 78 suited hands   (AKs, AQs, ..., 23s)
    - 78 offsuit hands  (AKo, AQo, ..., 23o)

    Two hands are isomorphic if they differ only in suit assignment
    (e.g., AhKh and AsKs are both "AKs"). *)

(** A canonical starting hand class. *)
type hand_class = {
  rank1 : Card.Rank.t;  (** higher rank (or equal for pairs) *)
  rank2 : Card.Rank.t;  (** lower rank (or equal for pairs) *)
  suited : bool;         (** true if suited (ignored for pairs) *)
}

(** Classify a 2-card hand into its canonical class.
    Rank order is normalized: rank1 >= rank2. *)
val classify : Card.t -> Card.t -> hand_class

(** Unique integer id for each class, in range [0, 168].
    Ordered: pairs first (AA=0 .. 22=12), then suited (AKs=13 ..),
    then offsuit (AKo=91 ..). *)
val canonical_id : hand_class -> int

(** Human-readable string: "AA", "AKs", "T9o", etc. *)
val to_string : hand_class -> string

(** All 169 canonical hand classes. *)
val all_classes : hand_class list

(** All specific (Card.t * Card.t) combos that belong to a class.
    Pairs: 6 combos.  Suited: 4 combos.  Offsuit: 12 combos. *)
val hands_in_class : hand_class -> (Card.t * Card.t) list
