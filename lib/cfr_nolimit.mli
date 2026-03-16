(** Monte Carlo Counterfactual Regret Minimization for No-Limit Hold'em.
 *
 *  External-sampling MCCFR over a bucketed NL Hold'em game.  Mirrors
 *  {!Cfr_abstract} but handles variable action counts per decision node
 *  (fold, check/call, each configured bet fraction, all-in) and
 *  stack-dependent action availability.
 *
 *  The betting tree is never materialised -- we recurse through game
 *  states directly, mirroring {!Nolimit_holdem}'s action generation.
 *
 *  Information sets are keyed by
 *    "B{preflop_bucket}:{flop_bucket}:{turn_bucket}:{river_bucket}|{history}"
 *  where history uses NL action encoding:
 *    'f' = fold, 'k' = check, 'c' = call,
 *    'h' = bet 0.5x pot, 'p' = bet 1x pot, 'd' = bet 2x pot,
 *    'a' = all-in, '/' separates streets. *)

(** Information set key *)
type info_key = string

(** Strategy: maps info_key -> action probabilities *)
type strategy = (string, float array) Hashtbl.Poly.t

(** Mutable CFR state for one player *)
type cfr_state = {
  regret_sum : (string, float array) Hashtbl.Poly.t;
  strategy_sum : (string, float array) Hashtbl.Poly.t;
}

(** [create ()] returns a fresh CFR state with empty tables. *)
val create : unit -> cfr_state

(** [sample_deal ()] draws 2 + 2 + 5 = 9 distinct cards uniformly at random
    from a 52-card deck.  Returns (p1_hole, p2_hole, board). *)
val sample_deal : unit -> (Card.t * Card.t) * (Card.t * Card.t) * Card.t list

(** [train_mccfr ~config ~abstraction ~iterations] runs external-sampling
    MCCFR for [iterations] iterations, alternating traverser each iteration.
    Returns (p1_average_strategy, p2_average_strategy).
    Prints convergence diagnostics every [~report_every] iterations. *)
val train_mccfr
  :  config:Nolimit_holdem.config
  -> abstraction:Abstraction.abstraction_partial
  -> iterations:int
  -> ?report_every:int
  -> unit
  -> strategy * strategy

(** [average_strategy state] normalises accumulated strategy sums to obtain
    the average strategy. *)
val average_strategy : cfr_state -> strategy

(** [make_info_key ~buckets ~round_idx ~history] constructs the information set
    key string from per-street bucket assignments and the action history.
    Format: "B{pf}:{fl}:{tu}:{ri}|{history}" (truncated to current street). *)
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
