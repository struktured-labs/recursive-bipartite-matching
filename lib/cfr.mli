(** Counterfactual Regret Minimization (CFR) for Rhode Island Hold'em.

    CFR computes a Nash equilibrium approximation for extensive-form games
    by iteratively accumulating counterfactual regrets and averaging
    strategies over all iterations.  The average strategy converges to a
    Nash equilibrium in two-player zero-sum games.

    Information sets are keyed by "{player_card}|{action_history}" where
    action_history encodes the path through the betting tree (e.g., "cb"
    for check-bet, "bcr" for bet-call-raise). *)

(** Information set key: what the player knows (their card + action history) *)
type info_key = string

(** Strategy: maps info_key -> action -> probability *)
type strategy = (info_key, float array) Hashtbl.Poly.t

(** CFR state for one player *)
type cfr_state = {
  regret_sum : (info_key, float array) Hashtbl.Poly.t;
  strategy_sum : (info_key, float array) Hashtbl.Poly.t;
  iterations : int;
}

(** [create ()] returns a fresh CFR state with empty regret and strategy tables. *)
val create : unit -> cfr_state

(** [train ~config ~community ~iterations] runs vanilla CFR for [iterations]
    iterations over all possible deals with the given [community] cards.
    Returns the average strategies for both players. *)
val train
  :  config:Rhode_island.config
  -> community:Card.t list
  -> iterations:int
  -> strategy * strategy

(** [exploitability ~config ~community p1_strategy p2_strategy] computes the
    sum of the maximum gain each player's best response can achieve against
    the opponent's strategy.  Lower values indicate closer approximation to
    Nash equilibrium; zero means exact Nash. *)
val exploitability
  :  config:Rhode_island.config
  -> community:Card.t list
  -> strategy
  -> strategy
  -> float

(** [exploitability_with_key_fn] is like [exploitability] but accepts a
    custom info key function, needed for evaluating compressed strategies
    that use cluster-based keys. *)
val exploitability_with_key_fn
  :  config:Rhode_island.config
  -> community:Card.t list
  -> info_key_fn:(int -> Card.t -> string -> info_key)
  -> strategy
  -> strategy
  -> float

(** [train_compressed ~config ~community ~ev_graph ~iterations] runs CFR on
    a game abstracted by the EV graph.  Information sets that belong to the
    same cluster share regrets and strategies, producing a coarser but faster
    equilibrium computation.  Returns (strategies, info_key_fn) so the
    caller can evaluate exploitability with the matching key function. *)
val train_compressed
  :  config:Rhode_island.config
  -> community:Card.t list
  -> ev_graph:Rhode_island.Node_label.t Ev_graph.t
  -> iterations:int
  -> strategy * strategy * (int -> Card.t -> string -> info_key)
