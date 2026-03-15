(** Recursive bipartite matching distance on trees.

    Computes the distance between two rooted trees by recursively applying
    minimum-cost bipartite matching (Hungarian method) on children at each
    level. Leaves ground the recursion with payoff difference.

    Structural mismatches (one tree has children the other doesn't) incur
    a phantom penalty proportional to the orphaned subtree's expected value. *)

(** Configuration for the distance computation *)
type config = {
  phantom_penalty : [ `Ev | `Size of float | `Constant of float ];
  (** How to penalize matching a subtree against a phantom (structural mismatch):
      - [`Ev]: penalty = |EV(subtree)|, natural for game trees
      - [`Size scale]: penalty = scale * size(subtree)
      - [`Constant c]: penalty = c for any unmatched subtree *)
  leaf_distance : (float -> float -> float);
  (** Distance between two leaf values. Default: absolute difference. *)
}

val default_config : config

(** [compute t1 t2] returns the recursive bipartite matching distance
    between trees [t1] and [t2] using default configuration. *)
val compute : 'a Tree.t -> 'a Tree.t -> float

(** [compute_with_config ~config t1 t2] with explicit configuration. *)
val compute_with_config : config:config -> 'a Tree.t -> 'a Tree.t -> float

(** [compute_with_matching ~config t1 t2] returns both the distance and
    the optimal matching at the root level (for use in merging). *)
val compute_with_matching
  :  config:config
  -> 'a Tree.t
  -> 'a Tree.t
  -> float * (int * int) list

(** Structural hash of a tree. Captures tree shape and leaf values but
    ignores labels, so structurally identical subtrees from different
    deals hash to the same value. *)
val structural_hash : 'a Tree.t -> int

(** Memoized distance computation. Caches results keyed by
    (tree1_hash, tree2_hash) for repeated subtree comparisons.
    Uses structural_hash, so trees with identical structure + leaf values
    but different labels share cached results. *)
val compute_memoized : 'a Tree.t -> 'a Tree.t -> float

(** Cache management for memoized distance. *)
module Memo : sig
  type memo_stats = {
    hits : int;
    misses : int;
  } [@@deriving sexp]

  (** Clear the memoization cache and reset hit/miss counters. *)
  val clear : unit -> unit

  (** Return current cache hit/miss statistics. *)
  val stats : unit -> memo_stats
end
