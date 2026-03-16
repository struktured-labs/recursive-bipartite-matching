(** Monte Carlo Counterfactual Regret Minimization for abstract Limit Hold'em.
 *
 *  External-sampling MCCFR over a bucketed (compressed) game representation.
 *  Each iteration samples a complete deal (2 hole cards per player + 5 board
 *  cards) and traverses the 4-round betting tree without materialising it.
 *
 *  Information sets are keyed by
 *    "B{preflop_bucket}:{flop_bucket}:{turn_bucket}:{river_bucket}|{history}"
 *  where history is an action string with '/' separating streets.
 *
 *  Action encoding:
 *  - 'f' = fold, 'k' = check, 'c' = call, 'b' = bet, 'r' = raise
 *  - '/' separates streets *)

(** Information set key *)
type info_key = string

(** Strategy: maps info_key -> action probabilities *)
type strategy = (string, float array) Hashtbl.Poly.t

(** Mutable CFR state for one player *)
type cfr_state = {
  regret_sum : (string, float array) Hashtbl.Poly.t;
  strategy_sum : (string, float array) Hashtbl.Poly.t;
}

(** Bucketing method selector. *)
type bucket_method =
  | Equity_based
  | Rbm_based of { epsilon : float; distance_config : Distance.config }

(** A single postflop cluster for RBM-based bucketing. *)
type postflop_cluster = {
  representative : Rhode_island.Node_label.t Tree.t;
  rep_ev : float;
  mutable member_count : int;
}

(** Per-street mutable cluster state for RBM-based post-flop bucketing.
    Clusters are keyed by street index: 1=flop, 2=turn, 3=river. *)
type postflop_state = {
  clusters : (int, postflop_cluster list ref) Hashtbl.t;
}

(** [create ()] returns a fresh CFR state with empty tables. *)
val create : unit -> cfr_state

(** [create_postflop_state ()] returns a fresh empty cluster state. *)
val create_postflop_state : unit -> postflop_state

(** [sample_deal ()] draws 2 + 2 + 5 = 9 distinct cards uniformly at random
    from a 52-card deck.  Returns (p1_hole, p2_hole, board) where board has
    exactly 5 cards [flop1; flop2; flop3; turn; river]. *)
val sample_deal : unit -> (Card.t * Card.t) * (Card.t * Card.t) * Card.t list

(** [train_mccfr ~config ~abstraction ~iterations] runs external-sampling
    MCCFR for [iterations] iterations, alternating traverser each iteration.
    Returns (p1_average_strategy, p2_average_strategy).
    Prints convergence diagnostics every [~report_every] iterations (default 10_000). *)
val train_mccfr
  :  config:Limit_holdem.config
  -> abstraction:Abstraction.abstraction_partial
  -> iterations:int
  -> ?report_every:int
  -> ?bucket_method:bucket_method
  -> unit
  -> strategy * strategy

(** [average_strategy state] normalises accumulated strategy sums to obtain
    the average strategy. *)
val average_strategy : cfr_state -> strategy

(** Convert an action to its single-character string representation. *)
val action_char : Rhode_island.Action.t -> string

(** [make_info_key ~buckets ~round_idx ~history] constructs the information set
    key string from per-street bucket assignments and the action history.
    Format: "B{pf}:{fl}:{tu}:{ri}|{history}" (truncated to current street). *)
val make_info_key : buckets:int array -> round_idx:int -> history:string -> info_key

(** [precompute_buckets ~abstraction ~hole_cards ~board] returns a 4-element
    array of bucket assignments for preflop, flop, turn, and river.
    Uses equity-based bucketing. *)
val precompute_buckets
  :  abstraction:Abstraction.abstraction_partial
  -> hole_cards:Card.t * Card.t
  -> board:Card.t list
  -> int array

(** [precompute_buckets_rbm ~abstraction ~game_config ~epsilon ~distance_config
    ~postflop ~hole_cards ~board ~player] returns a 4-element array of bucket
    assignments.  Preflop uses equity-based; post-flop uses RBM distance
    clustering with formal error bounds. *)
val precompute_buckets_rbm
  :  abstraction:Abstraction.abstraction_partial
  -> game_config:Limit_holdem.config
  -> epsilon:float
  -> distance_config:Distance.config
  -> postflop:postflop_state
  -> hole_cards:Card.t * Card.t
  -> board:Card.t list
  -> player:int
  -> int array

(** [precompute_buckets_equity] is the explicit equity-based bucketing function. *)
val precompute_buckets_equity
  :  abstraction:Abstraction.abstraction_partial
  -> hole_cards:Card.t * Card.t
  -> board:Card.t list
  -> int array

(** [postflop_cluster_count postflop] returns the total number of clusters
    across all post-flop streets. *)
val postflop_cluster_count : postflop_state -> int

(** [hand_score hole_cards board_visible] evaluates hand strength as a float
    in [0.0, 1.0] for equity-based bucketing.  Exposed for comparison. *)
val hand_score : Card.t * Card.t -> Card.t list -> float
