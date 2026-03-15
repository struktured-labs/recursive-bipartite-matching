(** EV Graph: compressed game tree via hierarchical clustering.

    Given a set of game trees (e.g., one per deal), clusters them using
    the recursive bipartite matching distance, then merges each cluster
    into a representative tree. The result is a DAG where multiple
    original game states map to the same compressed node.

    The compression threshold epsilon controls the tradeoff:
    - epsilon=0: no compression (every tree is its own cluster)
    - larger epsilon: more compression, more EV error *)

(** A cluster of game trees with a merged representative *)
type 'a cluster = {
  representative : 'a Tree.t;
  members : (int * 'a Tree.t) list;  (** (original_index, tree) *)
  diameter : float;                    (** max pairwise distance in cluster *)
}

(** The compressed EV graph *)
type 'a t = {
  clusters : 'a cluster list;
  epsilon : float;
  compression_ratio : float;  (** |original| / |clusters| *)
}

(** [compress ~epsilon trees] clusters [trees] by recursive bipartite matching
    distance, merging trees within distance [epsilon] of each other.
    Uses single-linkage agglomerative clustering. *)
(** Precomputed pairwise distance matrix for efficient repeated compression *)
type dist_matrix = float array array

(** [precompute_distances trees] computes the full pairwise distance matrix. *)
val precompute_distances
  :  ?distance_config:Distance.config
  -> 'a Tree.t list
  -> dist_matrix

val compress
  :  epsilon:float
  -> ?distance_config:Distance.config
  -> ?precomputed:dist_matrix
  -> 'a Tree.t list
  -> 'a t

(** [find_cluster graph tree] returns the index of the closest cluster
    to [tree] and the distance to its representative. *)
val find_cluster
  :  ?distance_config:Distance.config
  -> 'a t
  -> 'a Tree.t
  -> int * float

(** [ev_error graph] computes the maximum EV error across all clusters:
    max over all clusters of max |EV(member) - EV(representative)|. *)
val ev_error : _ t -> float

(** [report graph] returns a summary string of the compression. *)
val report : _ t -> string
