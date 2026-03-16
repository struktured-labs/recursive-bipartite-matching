(** Hand equity computation for Texas Hold'em.

    Provides hand strength evaluation and equity distribution computation
    used for card abstraction in poker AI.  Uses exhaustive enumeration
    over opponent hands and future board cards. *)

(** Compute hand strength: probability of winning at showdown against
    a uniformly random opponent hand, given known board cards.
    Enumerates all C(remaining,2) opponent hands.
    Ties count as 0.5 wins. *)
val hand_strength
  :  hole_cards:Card.t * Card.t
  -> board:Card.t list    (* 0, 3, 4, or 5 cards *)
  -> float                (* 0.0 to 1.0 *)

(** Hand strength against a specific opponent hand.
    Requires a complete 5-card board for 7-card evaluation,
    or fills remaining board by enumeration. *)
val matchup_result
  :  p1_cards:Card.t * Card.t
  -> p2_cards:Card.t * Card.t
  -> board:Card.t list
  -> [ `Win | `Lose | `Draw ]

(** Equity distribution: histogram of hand strengths across possible
    future boards.  For potential-aware abstraction (Ganzfried/Sandholm 2014).
    At the river (5 board cards), returns a single-bin histogram.
    At the turn (4 board cards), enumerates all remaining river cards.
    At the flop or preflop, uses Monte Carlo sampling of board completions. *)
val equity_distribution
  :  hole_cards:Card.t * Card.t
  -> board:Card.t list
  -> n_bins:int
  -> float array

(** Precompute equity for all 169 canonical starting hands (preflop).
    Returns array indexed by canonical hand ID (0-168).
    Uses Monte Carlo sampling (50k hands) per canonical hand, exploiting
    suit symmetry to require only one combo per class. *)
val preflop_equities : unit -> float array

(** Canonical hand representation for preflop grouping.
    "AKs" = Ace-King suited, "AKo" = Ace-King offsuit, "AA" = pocket pair. *)
type canonical_hand = {
  id : int;         (** 0-168 index *)
  name : string;    (** e.g., "AKs", "72o", "TT" *)
  rank1 : Card.Rank.t;
  rank2 : Card.Rank.t;
  suited : bool;
} [@@deriving sexp]

(** All 169 canonical hands, sorted by ID. *)
val all_canonical_hands : canonical_hand list

(** Map a specific hole card pair to its canonical hand. *)
val to_canonical : Card.t * Card.t -> canonical_hand

(** Compare two 7-card hands (2 hole + 5 board).
    Returns positive if hand1 wins, negative if hand2 wins, 0 for tie.
    Evaluates all C(7,5)=21 5-card subsets and picks the best. *)
val compare_7card
  :  Card.t * Card.t * Card.t * Card.t * Card.t * Card.t * Card.t
  -> Card.t * Card.t * Card.t * Card.t * Card.t * Card.t * Card.t
  -> int
