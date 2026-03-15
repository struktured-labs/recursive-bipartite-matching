(** Monte Carlo sampling location in the EV graph.

    Given a game state (known cards + action history), estimates which
    cluster in the compressed EV graph the state belongs to by:
    1. Sampling random continuations (rollouts) from the current state
    2. Comparing each sample against cluster representatives
    3. Producing a belief distribution over clusters via softmin

    This avoids the full recursive distance computation on the complete
    continuation tree, trading exactness for speed. *)

(** Belief distribution over clusters *)
type belief = {
  weights : (int * float) list;  (** (cluster_index, probability) *)
  map_cluster : int;             (** most likely cluster *)
  map_probability : float;       (** probability of MAP cluster *)
  entropy : float;               (** Shannon entropy of the belief *)
}

type config = {
  num_samples : int;      (** number of random rollouts *)
  sample_depth : int;     (** max depth of each rollout *)
  beta : float;           (** softmin temperature (higher = sharper) *)
  distance_config : Distance.config;
}

val default_config : config

(** [locate ~config graph ~game_state_tree] produces a belief distribution
    over clusters in [graph] by Monte Carlo sampling from [game_state_tree].

    [game_state_tree] is the full continuation tree from the current state
    (e.g., an information set tree). Samples are drawn by random path
    selection down to [sample_depth]. *)
val locate
  :  config:config
  -> 'a Ev_graph.t
  -> game_state_tree:'a Tree.t
  -> belief

(** [sample_subtree ~depth ~rng tree] extracts a random subtree of bounded
    depth by randomly selecting one child at each internal node. *)
val sample_subtree : depth:int -> 'a Tree.t -> 'a Tree.t
