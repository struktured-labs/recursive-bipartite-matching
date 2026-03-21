(** Bet-response subtree builder for action abstraction via RBM distance.

    Builds compact sampled trees representing the strategic consequences
    of a specific bet size.  Compatible with {!Distance.compute} for
    pairwise RBM distance computation between bet sizes. *)

(** Build a 2-ply response subtree for a specific bet size.

    Tree structure: opponent fold (leaf) + opponent call (showdown
    distribution) + opponent raise (simplified showdown).

    The tree values are scaled by actual pot sizes so that RBM distance
    reflects real EV differences between bet sizes. *)
val build_bet_response_tree
  :  pot:int
  -> effective_stack:int
  -> bet_frac:float
  -> hole_cards:Card.t * Card.t
  -> board_visible:Card.t list
  -> player:int
  -> ?max_opponents:int
  -> ?max_board_samples:int
  -> ?raise_fracs:float list
  -> unit
  -> Nolimit_holdem.Node_label.t Tree.t

(** Build response subtrees for multiple candidate bet sizes, averaged
    over sampled hands to produce hand-independent trees.

    Returns [(bet_frac, averaged_tree)] pairs suitable for pairwise
    RBM distance computation and agglomerative clustering. *)
val build_averaged_response_trees
  :  pot:int
  -> effective_stack:int
  -> candidate_fracs:float list
  -> sample_hands:(Card.t * Card.t) list
  -> board_visible:Card.t list
  -> ?max_opponents:int
  -> ?max_board_samples:int
  -> unit
  -> (float * Nolimit_holdem.Node_label.t Tree.t) list
