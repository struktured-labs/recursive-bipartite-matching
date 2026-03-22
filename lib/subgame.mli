(** Subgame decomposition for No-Limit Hold'em MCCFR training.

    Splits the monolithic MCCFR training into independent subgames:
    one per (preflop_history, flop_cluster) pair.  Each subgame trains
    only the postflop strategy for a specific preflop line and flop
    texture cluster, giving 10-50x speedup via parallelism and smaller
    tables.

    Flop clustering uses RBM distance on showdown distribution trees
    to group strategically similar flop textures. *)

(** Key identifying a unique subgame: a preflop action sequence paired
    with a flop texture cluster.  All postflop play following this
    (history, cluster) combination shares a single CFR table. *)
type subgame_key = {
  preflop_history : string;
  (** Action sequence before flop, e.g. "cc" or "phc".
      Uses Nolimit_holdem.Action.to_history_char encoding. *)
  flop_cluster : int;
  (** RBM cluster index for the flop texture. *)
}

(** Mutable per-subgame training state.  Contains a pair of CFR tables
    (one per player) and an iteration counter. *)
type subgame_state = {
  key : subgame_key;
  cfr_states : Compact_cfr.cfr_state array;
  (** 2-element array: P0, P1 *)
  mutable iteration_count : int;
}

(** Assembled decomposed strategy: a preflop blueprint plus per-subgame
    postflop strategies. *)
type decomposed_strategy = {
  preflop_p0 : Compact_cfr.strategy;
  preflop_p1 : Compact_cfr.strategy;
  subgame_strategies : (string, Compact_cfr.strategy * Compact_cfr.strategy) Hashtbl.t;
  (** Key = serialized subgame_key *)
  flop_cluster_map : (string, int) Hashtbl.t;
  (** Key = canonical flop string, value = cluster index *)
}

(** [cluster_flops ~epsilon ~n_sample_hands ~config ()] clusters
    representative flop boards by RBM distance on their showdown
    distribution trees.

    Samples ~200 random 3-card flops, builds characteristic trees
    using [showdown_distribution_tree] averaged over [n_sample_hands]
    sample hands, computes pairwise RBM distances, and agglomeratively
    clusters until distance > [epsilon].

    Returns [(flop_board, cluster_id)] pairs. *)
val cluster_flops
  :  epsilon:float
  -> n_sample_hands:int
  -> config:Nolimit_holdem.config
  -> ?n_flops:int
  -> ?distance_config:Distance.config
  -> unit
  -> (Card.t list * int) list

(** [flop_to_cluster ~cluster_map ~board] extracts the flop (first 3
    cards) from a 5-card board and looks up its cluster.  Returns the
    cluster of the nearest known flop if not found exactly. *)
val flop_to_cluster
  :  cluster_map:(string, int) Hashtbl.t
  -> board:Card.t list
  -> int

(** [enumerate_preflop_histories ~config ()] recursively enumerates all
    legal preflop action sequences that reach the flop (round_idx=1).
    Each sequence is a string of action characters (f/k/c/h/p/d/a etc).
    Filters to sequences where both players are still in (no fold). *)
val enumerate_preflop_histories
  :  config:Nolimit_holdem.config
  -> ?action_table:Action_abstraction.t
  -> unit
  -> string list

(** [reconstruct_state ~config ~preflop_history] replays the preflop
    action string to compute the [nl_state] at flop entry.  Parses
    each character, applies the action, and advances state.  Returns
    the [nl_state] with correct investments, stacks, and round_idx=1. *)
val reconstruct_state
  :  config:Nolimit_holdem.config
  -> preflop_history:string
  -> Compact_cfr.nl_state

(** [subgame_key_to_string key] serializes a subgame key to a string
    suitable for use as a hash table key. *)
val subgame_key_to_string : subgame_key -> string

(** [train_subgame ~config ~abstraction ~key ~entry_state ~flop_boards
      ~iterations ~bucket_method ()] trains MCCFR within a single
    subgame.  Samples deals: random hole cards + random board from
    [flop_boards] (completed to 5 cards).  Starts traversal at
    round_idx=1 with the given [entry_state].
    Returns the trained cfr_state pair (small, ~20K entries). *)
val train_subgame
  :  config:Nolimit_holdem.config
  -> abstraction:Abstraction.abstraction_partial
  -> key:subgame_key
  -> entry_state:Compact_cfr.nl_state
  -> flop_boards:Card.t list list
  -> iterations:int
  -> bucket_method:Compact_cfr.bucket_method
  -> ?action_table:Action_abstraction.t
  -> unit
  -> Compact_cfr.cfr_state array

(** [train_decomposed ~config ~abstraction ~blueprint_iterations
      ~subgame_iterations ~epsilon ~bucket_method ()] runs the full
    decomposed training pipeline:

    - Phase 1: Train blueprint (preflop only, few iterations)
    - Phase 2: Cluster flops via RBM distance
    - Phase 3: For each (preflop_history, flop_cluster) pair,
      train_subgame in parallel (each subgame is independent,
      fits in ~2MB)

    Returns the assembled [decomposed_strategy]. *)
val train_decomposed
  :  config:Nolimit_holdem.config
  -> abstraction:Abstraction.abstraction_partial
  -> blueprint_iterations:int
  -> subgame_iterations:int
  -> epsilon:float
  -> bucket_method:Compact_cfr.bucket_method
  -> ?num_parallel:int
  -> ?action_table:Action_abstraction.t
  -> ?n_flops:int
  -> ?n_sample_hands:int
  -> ?distance_config:Distance.config
  -> unit
  -> decomposed_strategy
