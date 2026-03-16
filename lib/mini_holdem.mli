(** Mini Texas Hold'em game tree generator.

    A 2-hole-card Hold'em variant bridging Rhode Island Hold'em and
    full Texas Hold'em:
    - 2 players
    - 2 hole cards each (like real Texas Hold'em)
    - 3 community cards (flop only, no turn/river)
    - 2 betting rounds: pre-flop and post-flop
    - Limit betting: configurable bet sizes, max raises per round
    - 5-card hand evaluation (2 hole + 3 community = 5 total)
    - Designed for reduced decks (e.g., 6 ranks x 4 suits = 24 cards) *)

(** Reuse action and node label types from Rhode Island Hold'em *)
module Action = Rhode_island.Action
module Node_label = Rhode_island.Node_label

(** Game configuration *)
type config = {
  deck : Card.t list;
  ante : int;
  bet_sizes : int list;  (** bet size per round *)
  max_raises : int;       (** max raises per betting round *)
} [@@deriving sexp]

val default_config : config
(** Default config: 6-rank deck (24 cards), ante=5, bets=[10;20], max_raises=1 *)

(** Generate the game tree for a specific deal.
    [p1_cards] and [p2_cards] are 2-card hole hands;
    [community] is the 3-card flop. *)
val game_tree_for_deal
  :  config:config
  -> p1_cards:Card.t * Card.t
  -> p2_cards:Card.t * Card.t
  -> community:Card.t list
  -> Node_label.t Tree.t

(** Generate a player's information set tree.
    The player knows their 2 hole cards and the 3 community cards,
    but not the opponent's 2 hole cards.  The IS tree branches over
    all C(remaining, 2) possible opponent hands. *)
val information_set_tree
  :  config:config
  -> player:int
  -> hole_cards:Card.t * Card.t
  -> community:Card.t list
  -> Node_label.t Tree.t

(** Remove cards from a deck *)
val remove_cards : Card.t list -> Card.t list -> Card.t list

(** All unordered 2-card combinations from a list *)
val all_pairs : Card.t list -> (Card.t * Card.t) list
