(** Compact-storage Monte Carlo CFR for No-Limit Hold'em.
 *
 *  Drop-in replacement for {!Cfr_nolimit} that uses monomorphic
 *  [(string, _) Hashtbl.t] instead of [Hashtbl.Poly.t].  This alone
 *  cuts per-entry overhead from ~500 bytes (polymorphic comparison,
 *  boxed keys, GC headers) to ~120-160 bytes (specialised string hash
 *  and compare, no boxing).  Tables are pre-sized to avoid expensive
 *  resize cascades during training.
 *
 *  All other logic is identical to {!Cfr_nolimit}. *)

(** Information set key *)
type info_key = string

(** Strategy: maps info_key -> action probabilities.
    Uses monomorphic string hashtable (NOT Poly). *)
type strategy = (string, float array) Hashtbl.t

(** Mutable CFR state for one player.
    Uses monomorphic string hashtables with pre-sizing. *)
type cfr_state = {
  regret_sum : (string, float array) Hashtbl.t;
  strategy_sum : (string, float array) Hashtbl.t;
}

(** [create ~size ()] returns a fresh CFR state with tables pre-sized
    to [size] entries.  Default [size] is 1_000_000. *)
val create : ?size:int -> unit -> cfr_state

(** [sample_deal ()] draws 2 + 2 + 5 = 9 distinct cards uniformly at random
    from a 52-card deck.  Returns (p1_hole, p2_hole, board). *)
val sample_deal : unit -> (Card.t * Card.t) * (Card.t * Card.t) * Card.t list

(** [save_checkpoint ~filename cfr_states] serialises raw CFR state
    (regret_sum + strategy_sum for both players) to [filename] using
    the chunked binary format.  Streams entries one at a time to avoid
    building a giant marshaled blob in memory.  This is the default. *)
val save_checkpoint : filename:string -> cfr_state array -> unit

(** [load_checkpoint ~filename] loads a previously saved CFR state from disk.
    Auto-detects the format: chunked binary (magic "RBMCFR01") or legacy
    Marshal format.
    Returns a 2-element array of cfr_states (P0, P1) with regret_sum and
    strategy_sum hash tables restored. Use with [~resume_from] in train_mccfr. *)
val load_checkpoint : filename:string -> cfr_state array

(** [save_checkpoint_chunked ~filename cfr_states] saves using the
    streaming chunked binary format (no memory spike). *)
val save_checkpoint_chunked : filename:string -> cfr_state array -> unit

(** [load_checkpoint_chunked ~filename] loads the chunked binary format. *)
val load_checkpoint_chunked : filename:string -> cfr_state array

(** [save_checkpoint_marshal ~filename cfr_states] saves using the legacy
    OCaml Marshal format.  Warning: builds the full serialized form in
    memory, causing ~2x memory spike. *)
val save_checkpoint_marshal : filename:string -> cfr_state array -> unit

(** [load_checkpoint_marshal ~filename] loads the legacy Marshal format. *)
val load_checkpoint_marshal : filename:string -> cfr_state array

(** [is_chunked_format ~filename] returns [true] when the file starts
    with the chunked-format magic header ["RBMCFR01"]. *)
val is_chunked_format : filename:string -> bool

(** Bucketing method selector for MCCFR training.

    [Equity_based]: fast O(1) equity quantization (default, no RBM guarantees).
    [Rbm_based { epsilon; distance_config }]: builds showdown distribution
    trees per street and clusters by RBM distance, preserving formal error
    bounds from Theorem 9.2. *)
type bucket_method =
  | Equity_based
  | Rbm_based of { epsilon : float; distance_config : Distance.config }

(** Mutable per-player per-street cluster state for RBM bucketing. *)
type postflop_state

(** [create_postflop_state ()] returns a fresh (empty) cluster state. *)
val create_postflop_state : unit -> postflop_state

(** [train_mccfr ~config ~abstraction ~iterations] runs external-sampling
    MCCFR for [iterations] iterations, alternating traverser each iteration.
    [~initial_size] pre-sizes the hash tables (default 1_000_000).
    [~checkpoint_every] saves raw CFR state every N iterations (default 0 = off).
    [~checkpoint_prefix] filename prefix for checkpoints (default "checkpoint").
    [~resume_from] loads a checkpoint file and continues training from that state.
    Returns (p1_average_strategy, p2_average_strategy).
    Prints convergence diagnostics every [~report_every] iterations. *)
val train_mccfr
  :  config:Nolimit_holdem.config
  -> abstraction:Abstraction.abstraction_partial
  -> iterations:int
  -> ?report_every:int
  -> ?initial_size:int
  -> ?checkpoint_every:int
  -> ?checkpoint_prefix:string
  -> ?resume_from:string
  -> ?bucket_method:bucket_method
  -> unit
  -> strategy * strategy

(** [average_strategy state] normalises accumulated strategy sums to obtain
    the average strategy. *)
val average_strategy : cfr_state -> strategy

(** [make_info_key ~buckets ~round_idx ~history] constructs the information set
    key string from per-street bucket assignments and the action history. *)
val make_info_key : buckets:int array -> round_idx:int -> history:string -> info_key

(** [precompute_buckets_equity ~abstraction ~hole_cards ~board] returns a
    4-element array of bucket assignments using equity-based bucketing. *)
val precompute_buckets_equity
  :  abstraction:Abstraction.abstraction_partial
  -> hole_cards:Card.t * Card.t
  -> board:Card.t list
  -> int array

(** [precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
      ~postflop ~hole_cards ~board ~player]
    returns a 4-element array of bucket assignments using RBM distance
    for post-flop streets.  Preflop uses the same canonical-hand abstraction
    as equity-based bucketing. *)
val precompute_buckets_rbm
  :  abstraction:Abstraction.abstraction_partial
  -> config:Nolimit_holdem.config
  -> epsilon:float
  -> distance_config:Distance.config
  -> postflop:postflop_state
  -> hole_cards:Card.t * Card.t
  -> board:Card.t list
  -> player:int
  -> int array

(** [regret_matching regrets] converts cumulative regrets into a strategy
    via the standard regret-matching formula.  Exposed for testing. *)
val regret_matching : float array -> float array

(** Internal NL game state, exposed for the standalone trainer. *)
type nl_state = {
  to_act : int;
  round_idx : int;
  num_raises : int;
  current_bet : int;
  p_invested : int array;
  p_stack : int array;
  round_start_invested : int array;
  actions_remaining : int;
}

(** [mccfr_traverse ~config ~p1_cards ~p2_cards ~board ~p1_buckets ~p2_buckets
      ~history ~state ~traverser ~cfr_states]
    performs one external-sampling MCCFR traversal.
    Returns the counterfactual value for the traverser. *)
val mccfr_traverse
  :  config:Nolimit_holdem.config
  -> p1_cards:Card.t * Card.t
  -> p2_cards:Card.t * Card.t
  -> board:Card.t list
  -> p1_buckets:int array
  -> p2_buckets:int array
  -> history:string
  -> state:nl_state
  -> traverser:int
  -> cfr_states:cfr_state array
  -> float

(** [copy_cfr_state state] returns a deep copy of [state], including
    independent copies of all regret_sum and strategy_sum arrays. *)
val copy_cfr_state : cfr_state -> cfr_state

(** [merge_cfr_state_into ~dst ~src] adds all regret_sum and strategy_sum
    values from [src] into [dst] element-wise.  Mutates [dst] in place.
    Keys present in [src] but not [dst] are copied. *)
val merge_cfr_state_into : dst:cfr_state -> src:cfr_state -> unit

(** [train_mccfr_parallel ~config ~abstraction ~iterations] runs
    external-sampling MCCFR across [~num_domains] OCaml 5 domains.
    Each domain maintains its own independent cfr_state and runs
    iterations concurrently.  After all iterations complete, worker
    states are merged by summing regret_sum and strategy_sum values
    (valid because MCCFR regret/strategy sums are additive).

    Parameters are identical to {!train_mccfr} with the addition of:
    - [~num_domains] — number of worker domains (default: CPU count - 1)

    Returns (p1_average_strategy, p2_average_strategy). *)
val train_mccfr_parallel
  :  config:Nolimit_holdem.config
  -> abstraction:Abstraction.abstraction_partial
  -> iterations:int
  -> ?report_every:int
  -> ?initial_size:int
  -> ?checkpoint_every:int
  -> ?checkpoint_prefix:string
  -> ?resume_from:string
  -> ?num_domains:int
  -> ?bucket_method:bucket_method
  -> unit
  -> strategy * strategy
