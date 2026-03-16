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

(** [create ()] returns a fresh CFR state with empty tables. *)
val create : unit -> cfr_state

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
  -> unit
  -> strategy * strategy

(** [average_strategy state] normalises accumulated strategy sums to obtain
    the average strategy. *)
val average_strategy : cfr_state -> strategy

(** [make_info_key ~buckets ~round_idx ~history] constructs the information set
    key string from per-street bucket assignments and the action history.
    Format: "B{pf}:{fl}:{tu}:{ri}|{history}" (truncated to current street). *)
val make_info_key : buckets:int array -> round_idx:int -> history:string -> info_key

(** [precompute_buckets ~abstraction ~hole_cards ~board] returns a 4-element
    array of bucket assignments for preflop, flop, turn, and river. *)
val precompute_buckets
  :  abstraction:Abstraction.abstraction_partial
  -> hole_cards:Card.t * Card.t
  -> board:Card.t list
  -> int array
