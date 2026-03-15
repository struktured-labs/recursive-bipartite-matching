(** Error bounds for EV graph compression.

    The key theoretical result: the recursive bipartite matching distance
    directly bounds the EV error introduced by merging game trees.

    For two trees T1, T2 with d(T1, T2) = epsilon:
    - The merged representative T* has EV within epsilon of both originals
    - Any strategy computed on T* has exploitability bounded by epsilon
    - When epsilon = 0, the compression is exact (zero error)

    These bounds are intrinsic to the distance metric — they don't depend
    on the abstraction method, unlike Kroer & Sandholm's bounds. *)

(** Compute the maximum leaf-level EV error for a single merge.
    Given two trees and their merged representative, returns
    the maximum absolute difference between any leaf in the originals
    and the corresponding leaf in the merged tree. *)
val max_leaf_error
  :  ?distance_config:Distance.config
  -> 'a Tree.t
  -> 'a Tree.t
  -> 'a Tree.t  (* merged *)
  -> float

(** Compute the EV error bound for an entire EV graph.
    Returns (max_error, avg_error, errors_by_cluster). *)
val graph_error_analysis
  :  'a Ev_graph.t
  -> float * float * (int * float) list

(** Verify that the distance-based bound holds: for each cluster,
    the EV error should be <= distance/2 for equal-weight merges.
    Returns list of (cluster_index, ev_error, distance_bound, passed). *)
val verify_bounds
  :  ?distance_config:Distance.config
  -> 'a Ev_graph.t
  -> (int * float * float * bool) list

(** Report on bound verification. *)
val report
  :  ?distance_config:Distance.config
  -> 'a Ev_graph.t
  -> string
