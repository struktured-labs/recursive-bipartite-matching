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

(** Remove a list of cards from a deck. *)
val remove_cards : Card.t list -> Card.t list -> Card.t list

(** All unordered 2-card combinations from a list. *)
val all_pairs : Card.t list -> (Card.t * Card.t) list
