(** No-Limit Hold'em game tree generator with multi-player support.

    Key differences from {!Limit_holdem}:
    - Variable bet sizes: fraction-of-pot bets (e.g. 0.5x, 1x, 2x) + all-in
    - Each player has a stack of chips that depletes over the hand
    - Multi-player (2-10): betting goes around the table until all active
      players have acted and bets are matched

    For tractability, bet sizes are discretised to a configurable list of
    pot fractions.  The number of actions per decision node is
    [2 + len(bet_fractions) + 1]: fold, check/call, each fraction, all-in. *)

(** No-limit actions.  Extends {!Rhode_island.Action} with sized bets. *)
module Action : sig
  type t =
    | Fold
    | Check
    | Call
    | Bet_frac of float   (** Bet/raise as a fraction of the pot *)
    | All_in
  [@@deriving sexp, compare, equal]

  val to_string : t -> string

  (** Convert to a short history character for info-set key building.
      Fold="f", Check="k", Call="c", Bet_frac 0.5="h", 1.0="p", 2.0="d",
      other fractions use "bN" format, All_in="a". *)
  val to_history_char : t -> string
end

(** Node label for no-limit game trees.  Mirrors {!Rhode_island.Node_label}
    but uses {!Action.t} for the decision action list. *)
module Node_label : sig
  type t =
    | Root
    | Chance of { description : string }
    | Decision of { player : int; actions_available : Action.t list }
    | Terminal of { winners : int list; pot : int }
  [@@deriving sexp]
end

(** Per-player state at any point during the hand. *)
type player_state = {
  cards : Card.t * Card.t;
  stack : int;    (** remaining chips (not yet invested) *)
  folded : bool;
  all_in : bool;
  invested : int; (** total chips invested this hand *)
}

(** Game configuration. *)
type config = {
  deck : Card.t list;
  small_blind : int;
  big_blind : int;
  starting_stack : int;
  bet_fractions : float list;
  max_raises_per_round : int;
  num_players : int;
}

(** Standard heads-up config: 200bb deep, bet fractions [0.5; 1.0; 2.0]. *)
val standard_config : config

(** Short-stack heads-up config: 20bb deep, bet fractions [0.5; 1.0].
    Produces much smaller trees. *)
val short_stack_config : config

(** 6-max short-stack config: 20bb deep, bet fractions [0.5; 1.0],
    6 players. *)
val six_max_short_config : config

(** Expanded heads-up config: 200bb deep, 7 bet sizes
    [0.25; 0.33; 0.5; 0.75; 1.0; 1.5; 2.0]. *)
val expanded_config : config

(** Generate heads-up no-limit game tree for a specific deal.
    [board] must contain exactly 5 community cards. *)
val game_tree_for_deal
  :  config:config
  -> p1_cards:Card.t * Card.t
  -> p2_cards:Card.t * Card.t
  -> board:Card.t list
  -> Node_label.t Tree.t

(** Generate N-player no-limit game tree for a specific deal.
    [players] has one entry per seat; [board] must contain exactly 5 cards.
    Positions: seat 0 = SB (or button in heads-up), seat 1 = BB,
    seat 2+ = UTG, MP, CO, BTN... *)
val game_tree_for_deal_n
  :  config:config
  -> players:player_state array
  -> board:Card.t list
  -> Node_label.t Tree.t

(** Build a compact showdown distribution tree for RBM-based bucketing.

    Samples [max_board_samples] board completions and [max_opponents]
    opponent hands to create a small tree capturing the hand's strength
    distribution at a given board state.  The tree structure is compatible
    with {!Distance.compute} for RBM distance computation.

    [board_visible] is the currently visible board cards (3 for flop,
    4 for turn, 5 for river).  [player] is 0 or 1 (determines value
    sign convention). *)
val showdown_distribution_tree
  :  ?max_opponents:int
  -> ?max_board_samples:int
  -> config:config
  -> player:int
  -> hole_cards:Card.t * Card.t
  -> board_visible:Card.t list
  -> unit
  -> Node_label.t Tree.t
