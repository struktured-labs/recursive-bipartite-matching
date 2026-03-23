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
type info_key = Int64.t

(** Strategy: maps info_key -> action probabilities.
    Uses monomorphic Int64 hashtable (NOT Poly). *)
type strategy = (Int64.t, float array) Hashtbl.t

(** Paired regret + strategy data for a single information set.
    Both regret and strategy values are packed into a single [data] array
    of length [2 * n_actions]: the first [n_actions] floats are regrets,
    the second [n_actions] floats are strategy sums.  This halves the
    number of OCaml heap allocations per entry (one array instead of two). *)
type cfr_entry = {
  data : float array;
  n_actions : int;
}

(** Mutable CFR state for one player.
    Uses a single monomorphic Int64 hashtable with paired entries. *)
type cfr_state = {
  entries : (Int64.t, cfr_entry) Hashtbl.t;
}

(** [create ~size ()] returns a fresh CFR state with tables pre-sized
    to [size] entries.  Default [size] is 1_000_000. *)
val create : ?size:int -> unit -> cfr_state

(* ------------------------------------------------------------------ *)
(* Variance-Reduced MCCFR (VR-MCCFR+)                                 *)
(* Schmid et al., AAAI 2019                                            *)
(* ------------------------------------------------------------------ *)

(** Per-info-set baseline table for VR-MCCFR: maps [info_key] to
    per-action baseline estimates (exponential moving averages of
    observed counterfactual values).  Baselines are training-time only
    and are NOT saved in checkpoints. *)
type vr_baselines = (Int64.t, float array) Hashtbl.t

(** [create_baselines ~size ()] returns a fresh baseline table
    pre-sized to [size] entries.  Default [size] is 100_000. *)
val create_baselines : ?size:int -> unit -> vr_baselines

(** [get_baseline baselines key ~n_actions] returns the per-action
    baseline array for [key], lazily creating a zero-filled array
    of length [n_actions] if not present. *)
val get_baseline : vr_baselines -> info_key -> n_actions:int -> float array

(** [update_baseline baseline observed ~alpha] moves the baseline
    towards [observed] using exponential moving average:
    baseline[i] <- (1 - alpha) * baseline[i] + alpha * observed[i]. *)
val update_baseline : float array -> float array -> alpha:float -> unit

(** [get_dls_baselines ()] returns the domain-local VR baselines.
    Returns [None] when VR-MCCFR is disabled.  Each OCaml 5 domain
    has its own independent baselines. *)
val get_dls_baselines : unit -> vr_baselines array option

(** [set_dls_baselines v] sets the domain-local VR baselines. *)
val set_dls_baselines : vr_baselines array option -> unit

(** [get_dls_vr_iter ()] returns the domain-local VR-MCCFR iteration
    counter (for harmonic baseline alpha). *)
val get_dls_vr_iter : unit -> int

(** [set_dls_vr_iter v] sets the domain-local VR iteration counter. *)
val set_dls_vr_iter : int -> unit

(** [get_dls_lcfr_iter ()] returns the domain-local LCFR iteration
    counter.  When > 0, [accumulate_strategy] weights contributions
    by the iteration number (linear averaging).  0 = disabled. *)
val get_dls_lcfr_iter : unit -> int

(** [set_dls_lcfr_iter v] sets the domain-local LCFR iteration. *)
val set_dls_lcfr_iter : int -> unit

(** [find_or_add_entry state key ~num_actions] looks up the CFR entry
    for [key], creating a zero-filled entry if absent.  Exposed for
    testing. *)
val find_or_add_entry : cfr_state -> info_key -> num_actions:int -> cfr_entry

(** [entry_regret entry i] returns [entry.data.(i)] (the i-th regret). *)
val entry_regret : cfr_entry -> int -> float

(** [entry_strategy entry i] returns [entry.data.(n_actions + i)] (the i-th strategy sum). *)
val entry_strategy : cfr_entry -> int -> float

(** [set_entry_regret entry i v] sets the i-th regret to [v]. *)
val set_entry_regret : cfr_entry -> int -> float -> unit

(** [set_entry_strategy entry i v] sets the i-th strategy sum to [v]. *)
val set_entry_strategy : cfr_entry -> int -> float -> unit

(** [entry_regrets_sub entry] returns a fresh copy of the regret portion. *)
val entry_regrets_sub : cfr_entry -> float array

(** [entry_strategy_sub entry] returns a fresh copy of the strategy portion. *)
val entry_strategy_sub : cfr_entry -> float array

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
    [~dcfr] enables Discounted CFR (Brown & Sandholm 2019), which discounts
    older regret and strategy sums each iteration (default false).
    [~prune_threshold] enables per-action Regret-Based Pruning (RBP): during
    traversal, actions with cumulative regret below this threshold are skipped
    (default -300_000_000; pass [Float.infinity] to disable).
    [~vr_mccfr] enables Variance-Reduced MCCFR (Schmid et al., AAAI 2019):
    maintains per-info-set baselines that absorb value fluctuations, yielding
    the same expected regret updates with dramatically lower variance (default
    false).  Baselines use a harmonic EMA schedule (alpha = 1/(iter+1)).
    [~lcfr] enables Linear CFR (LCFR) iteration-weighted strategy
    averaging: each iteration's strategy contribution is weighted by the
    iteration number, so later (better) strategies dominate the average.
    Converges 2-5x faster than uniform averaging.  Combines naturally
    with [~dcfr] (default false).
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
  -> ?action_table:Action_abstraction.t
  -> ?dcfr:bool
  -> ?prune_threshold:float
  -> ?vr_mccfr:bool
  -> ?lcfr:bool
  -> unit
  -> strategy * strategy

(** [average_strategy state] normalises accumulated strategy sums to obtain
    the average strategy. *)
val average_strategy : cfr_state -> strategy

(** [make_info_key ~buckets ~round_idx ~history] hashes bucket assignments,
    round index, and action history into a single [Int64.t] via FNV-1a.
    Zero allocation --- no intermediate strings. *)
val make_info_key : buckets:int array -> round_idx:int -> history:string -> info_key

(** [make_info_key_string ~buckets ~round_idx ~history] constructs the old
    human-readable string key (e.g. ["B34:29:78:3|cc/kk/kh"]) for debugging
    and diagnostics.  Not used in the hot path. *)
val make_info_key_string : buckets:int array -> round_idx:int -> history:string -> string

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

(** [regret_matching_with_pruning regrets ~prune_threshold] is like
    [regret_matching] but zeroes out actions whose cumulative regret
    falls below [prune_threshold].  Returns [(strategy, pruned)] where
    [pruned.(i)] is [true] when action [i] was pruned.  Exposed for
    testing. *)
val regret_matching_with_pruning
  : float array -> prune_threshold:float -> float array * bool array

(* ------------------------------------------------------------------ *)
(* Discounted CFR (DCFR) — Brown & Sandholm 2019                      *)
(* ------------------------------------------------------------------ *)

(** DCFR hyperparameters.  [alpha] and [beta] control the discount
    factor for positive/negative regrets respectively; [gamma] controls
    the strategy-sum discount.  Recommended defaults from the paper:
    alpha=1.5, beta=0.0, gamma=2.0. *)
type dcfr_params = {
  alpha : float;
  beta  : float;
  gamma : float;
}

(** Recommended DCFR hyperparameters (alpha=1.5, beta=0.0, gamma=2.0). *)
val default_dcfr_params : dcfr_params

(** DCFR hyperparameter schedule selector.
    [Fixed params]: constant hyperparameters (original DCFR).
    [Linear_weighted]: LCFR -- weight each iteration's strategy
      contribution by its iteration number, so later (better)
      strategies dominate the average.  2-5x faster convergence.
      See "Hyperparameter Schedules for Discounted CFR" (2024).
    [Adaptive { base }]: placeholder for future learned schedules. *)
type dcfr_schedule =
  | Fixed of dcfr_params
  | Linear_weighted
  | Adaptive of { base : dcfr_params }

(** Per-iteration discount factors computed from [dcfr_params]. *)
type dcfr_weights = {
  pos_regret_weight : float;
  neg_regret_weight : float;
  strategy_weight   : float;
}

(** [compute_dcfr_weights params ~iter] computes discount factors for
    iteration [iter] from the given DCFR hyperparameters. *)
val compute_dcfr_weights : dcfr_params -> iter:int -> dcfr_weights

(** [apply_dcfr_discount state weights] multiplies all regret and
    strategy sums in [state] by the corresponding DCFR discount
    factors.  Mutates [state] in place. *)
val apply_dcfr_discount : cfr_state -> dcfr_weights -> unit

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
    independent copies of all regret and strategy arrays. *)
val copy_cfr_state : cfr_state -> cfr_state

(** [merge_cfr_state_into ~dst ~src] adds all regret and strategy
    values from [src] into [dst] element-wise.  Mutates [dst] in place.
    Keys present in [src] but not [dst] are copied. *)
val merge_cfr_state_into : dst:cfr_state -> src:cfr_state -> unit

(** [train_mccfr_parallel ~config ~abstraction ~iterations] runs
    external-sampling MCCFR across [~num_domains] OCaml 5 domains.
    Each domain maintains its own independent cfr_state and runs
    iterations concurrently.  After all iterations complete, worker
    states are merged by summing regret_sum and strategy_sum values
    (valid because MCCFR regret/strategy sums are additive).

    When [~vr_mccfr:true], each domain creates independent baseline
    tables via [Domain.DLS], avoiding cross-domain data races.

    Parameters are identical to {!train_mccfr} with the addition of:
    - [~num_domains] -- number of worker domains (default: CPU count - 1)

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
  -> ?action_table:Action_abstraction.t
  -> ?dcfr:bool
  -> ?prune_threshold:float
  -> ?vr_mccfr:bool
  -> ?lcfr:bool
  -> unit
  -> strategy * strategy
