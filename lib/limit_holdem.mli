(** Full Limit Hold'em game tree generator.

    Standard 2-player Limit Texas Hold'em with 4 betting rounds:
    - Preflop:  2 hole cards each, small blind + big blind, small bet
    - Flop:     3 community cards, small bet
    - Turn:     1 community card,  big bet
    - River:    1 community card,  big bet
    - Showdown: best 5 of 7 cards (Hand_eval7)

    Blind structure: SB posts small blind, BB posts big blind.
    Preflop: SB acts first.  Post-flop: non-dealer (P1, SB) acts first.

    Reuses Action and Node_label types from Rhode_island. *)

module Action = Rhode_island.Action
module Node_label = Rhode_island.Node_label

(** Game configuration for Limit Hold'em. *)
type config = {
  deck : Card.t list;
  small_blind : int;
  big_blind : int;
  small_bet : int;    (** preflop and flop betting increment *)
  big_bet : int;      (** turn and river betting increment *)
  max_raises : int;   (** maximum raises per betting round (typically 4) *)
}

(** Standard Limit Hold'em config: SB=1, BB=2, small_bet=2, big_bet=4,
    max_raises=4, full 52-card deck. *)
val standard_config : config

(** Generate the game tree for a specific fully-known deal.
    [p1_cards] = SB's hole cards, [p2_cards] = BB's hole cards,
    [board] = exactly 5 community cards (flop1, flop2, flop3, turn, river).

    The tree includes all 4 betting rounds with decision nodes
    and terminal nodes for fold/showdown outcomes. *)
val game_tree_for_deal
  :  config:config
  -> p1_cards:Card.t * Card.t
  -> p2_cards:Card.t * Card.t
  -> board:Card.t list
  -> Node_label.t Tree.t

(** Build a compact showdown distribution tree for RBM distance.
    Much cheaper than a full IS tree (microseconds vs milliseconds).
    Samples opponent hands and board completions, evaluates showdown
    outcomes, returns a two-level tree of showdown values.
    Captures the strategic hand strength distribution needed for RBM
    distance while being fast enough for per-iteration use. *)
val showdown_distribution_tree
  :  ?max_opponents:int
  -> ?max_board_samples:int
  -> config:config
  -> player:int
  -> hole_cards:Card.t * Card.t
  -> board_visible:Card.t list
  -> unit
  -> Node_label.t Tree.t

(** Build a game tree starting from a specific betting round.
    Unlike [game_tree_for_deal], starts at [round_idx] with [pot_so_far]
    chips already invested.  [board] must be exactly 5 cards. *)
val game_tree_from_street
  :  config:config
  -> p1_cards:Card.t * Card.t
  -> p2_cards:Card.t * Card.t
  -> board:Card.t list
  -> round_idx:int
  -> pot_so_far:int
  -> Node_label.t Tree.t

(** Build an information set tree for [player] at a given street.

    Aggregates over all possible opponent hole-card pairs AND remaining
    board cards.  [board_visible] is the known community cards (3 for flop,
    4 for turn, 5 for river).  [round_idx] is the street (1=flop, 2=turn,
    3=river).  [pot_so_far] is the total chips invested before this street.

    Subsamples opponent hands (at most [?max_opponents], default 20) and
    board completions (at most [?max_board_samples], default 10) to keep
    tree construction fast.  The resulting tree has at most
    max_board_samples * max_opponents children.

    The resulting tree captures strategic similarity for RBM distance
    comparison: two hands that play out similarly against the field will
    have small tree distance. *)
val information_set_tree
  :  ?max_opponents:int
  -> ?max_board_samples:int
  -> config:config
  -> player:int
  -> hole_cards:Card.t * Card.t
  -> board_visible:Card.t list
  -> round_idx:int
  -> pot_so_far:int
  -> unit
  -> Node_label.t Tree.t

(** Remove a list of cards from a deck. *)
val remove_cards : Card.t list -> Card.t list -> Card.t list

(** All unordered 2-card combinations from a list. *)
val all_pairs : Card.t list -> (Card.t * Card.t) list
