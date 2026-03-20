(** Parallel pairwise distance matrix using OCaml 5 domains.

    Uses Domainslib.Task for work-stealing parallelism.  Each (i,j) pair
    in the upper triangle is independent, so parallelism is trivial. *)

(** [default_num_domains ()] returns [Domain.recommended_domain_count () - 1],
    the default number of worker domains used for parallel computations. *)
val default_num_domains : unit -> int

(** [precompute_distances_parallel ~num_domains trees] computes the full
    pairwise distance matrix using [num_domains] parallel workers.

    Defaults to [Domain.recommended_domain_count () - 1] worker domains. *)
val precompute_distances_parallel
  :  ?num_domains:int
  -> ?distance_config:Distance.config
  -> 'a Tree.t list
  -> Ev_graph.dist_matrix

(** [precompute_distances_parallel_pruned ~threshold trees] computes the
    pairwise distance matrix in parallel, skipping full computation when
    |EV(T1) - EV(T2)| > threshold (set to infinity). Returns
    (matrix, num_computed, num_skipped). *)
val precompute_distances_parallel_pruned
  :  ?num_domains:int
  -> ?distance_config:Distance.config
  -> threshold:float
  -> 'a Tree.t list
  -> Ev_graph.dist_matrix * int * int

(** [precompute_distances_parallel_fast ~threshold trees] combines
    EV pruning and progressive depth truncation in parallel. Returns
    (matrix, (ev_pruned, shallow_pruned, full_computed)). *)
val precompute_distances_parallel_fast
  :  ?num_domains:int
  -> ?distance_config:Distance.config
  -> threshold:float
  -> 'a Tree.t list
  -> Ev_graph.dist_matrix * (int * int * int)

(** [precompute_distances_parallel_memoized] same but uses
    [Distance.compute_memoized] semantics (structural-hash keyed).

    Note: the memo cache is per-domain (no sharing) to avoid lock
    contention.  Each domain builds its own [Hashtbl] and the results
    are written directly into the shared output matrix (disjoint
    indices, no data race). *)
val precompute_distances_parallel_memoized
  :  ?num_domains:int
  -> 'a Tree.t list
  -> Ev_graph.dist_matrix
