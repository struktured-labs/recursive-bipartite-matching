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
    Marshal format.  Compatible with {!train_mccfr_nl}'s output. *)
val save_checkpoint : filename:string -> cfr_state array -> unit

(** [train_mccfr ~config ~abstraction ~iterations] runs external-sampling
    MCCFR for [iterations] iterations, alternating traverser each iteration.
    [~initial_size] pre-sizes the hash tables (default 1_000_000).
    [~checkpoint_every] saves raw CFR state every N iterations (default 0 = off).
    [~checkpoint_prefix] filename prefix for checkpoints (default "checkpoint").
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
