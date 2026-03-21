(** Action abstraction via RBM distance on bet-response subtrees.

    Clusters candidate bet sizes using the same RBM distance metric
    and error bounds as state abstraction (Theorem 9.2).  Two bet sizes
    whose response subtrees have RBM distance d can be merged with at
    most d/2 EV error.

    Error composes additively with state abstraction:
    total per-step error ≤ (ε_state + ε_action) / 2. *)

(** A cluster of strategically equivalent bet sizes. *)
type action_cluster = {
  centroid_frac : float;      (** mean of merged fractions *)
  member_fracs : float list;  (** all fractions in this cluster *)
  representative : Nolimit_holdem.Node_label.t Tree.t;
  diameter : float;           (** max intra-cluster RBM distance *)
}

(** Game context determining optimal bet sizes. *)
type action_context = {
  street : int;
  pot_bucket : int;
  stack_bucket : int;
  raise_count : int;
}

(** Precomputed action abstraction mapping contexts to optimal bet fractions. *)
type t

(** Discretize pot size to bucket index (log-scale relative to big blind). *)
val pot_to_bucket : big_blind:int -> int -> int

(** Discretize effective stack to bucket index (log-scale). *)
val stack_to_bucket : big_blind:int -> int -> int

(** Cluster candidate bet sizes for a single game context.
    Returns clusters sorted by centroid fraction. *)
val cluster_bet_sizes
  :  pot:int
  -> effective_stack:int
  -> candidate_fracs:float list
  -> epsilon:float
  -> sample_hands:(Card.t * Card.t) list
  -> board_visible:Card.t list
  -> ?distance_config:Distance.config
  -> unit
  -> action_cluster list

(** Precompute action abstraction for a grid of game contexts.
    Iterates over (street, pot, stack, raise_count) combinations
    and clusters the candidate bet sizes for each. *)
val precompute
  :  big_blind:int
  -> epsilon:float
  -> candidate_fracs:float list
  -> sample_hands:(Card.t * Card.t) list
  -> pot_values:int list
  -> stack_values:int list
  -> unit
  -> t

(** Look up optimal bet fractions for a given game context.
    Falls back to full candidate list if context not in table. *)
val lookup
  :  t
  -> big_blind:int
  -> street:int
  -> pot:int
  -> effective_stack:int
  -> raise_count:int
  -> float list

(** Number of unique contexts in the table. *)
val num_contexts : t -> int

(** Average number of surviving bet sizes per context. *)
val avg_actions_per_context : t -> float
