(** Rhode Island Hold'em game tree generator.

    Rules (Gilpin & Sandholm 2005):
    - 2 players, configurable deck
    - Ante: 5 chips each
    - Each player dealt 1 hole card
    - 3 betting rounds: pre-flop (bet=10), post-flop (bet=20), post-turn (bet=20)
    - Max 3 raises per betting round
    - 1 community card after round 1 (flop), 1 after round 2 (turn)
    - Showdown: best 3-card hand wins
    - 3-card rankings: trips > straight > flush > pair > high *)

module Action : sig
  type t = Fold | Check | Call | Bet | Raise
  [@@deriving sexp, compare, equal]

  val to_string : t -> string
end

module Node_label : sig
  type t =
    | Root
    | Chance of { description : string }
    | Decision of { player : int; actions_available : Action.t list }
    | Terminal of { winner : int option; pot : int }
      (** winner = None means split pot *)
  [@@deriving sexp]
end

(** Game configuration *)
type config = {
  deck : Card.t list;
  ante : int;
  bet_sizes : int list;  (** bet size per round: [10; 20; 20] for standard *)
  max_raises : int;       (** max raises per betting round *)
} [@@deriving sexp]

val standard_config : config
val small_config : n_ranks:int -> config

(** Generate the complete game tree for a specific deal.
    [p1_card], [p2_card] are hole cards; [community] are dealt in order. *)
val game_tree_for_deal
  :  config:config
  -> p1_card:Card.t
  -> p2_card:Card.t
  -> community:Card.t list
  -> Node_label.t Tree.t

(** Generate the full game tree including all chance nodes (all possible deals).
    WARNING: This is huge for 52-card deck. Use small_config for testing. *)
val full_game_tree : config:config -> Node_label.t Tree.t

(** Number of distinct deals (hole card combos x community card combos) *)
val num_deals : config:config -> int

(** Generate a single player's "information set" tree: the game tree from
    one player's perspective, with opponent's card unknown.
    This is what the player actually reasons about. *)
val information_set_tree
  :  config:config
  -> player:int
  -> hole_card:Card.t
  -> community:Card.t list
  -> Node_label.t Tree.t
