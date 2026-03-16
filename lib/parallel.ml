(** Parallel pairwise distance matrix using OCaml 5 domains.

    Uses Domainslib.Task for work-stealing parallelism. *)

let default_num_domains () =
  Int.max 1 (Domain.recommended_domain_count () - 1)

let precompute_distances_parallel
    ?(num_domains = default_num_domains ())
    ?(distance_config = Distance.default_config)
    (trees : 'a Tree.t list)
  =
  let n = List.length trees in
  let tree_arr = Array.of_list trees in
  (* Pre-allocate the n x n matrix with zeros *)
  let dist = Array.init n ~f:(fun _ -> Array.create ~len:n 0.0) in
  let n_pairs = n * (n - 1) / 2 in
  match n_pairs with
  | 0 -> dist
  | _ ->
    (* Flatten upper triangle to a 1D index space.
       Each linear index k maps to a unique (i, j) pair with i < j. *)
    let pool = Domainslib.Task.setup_pool ~num_domains () in
    Domainslib.Task.run pool (fun () ->
      Domainslib.Task.parallel_for pool ~start:0 ~finish:(n_pairs - 1)
        ~body:(fun k ->
          (* Map linear index k -> (i, j) pair in upper triangle.
             Row i starts at offset i*n - i*(i+1)/2 - i, but it is simpler
             to invert:  i = n - 1 - floor((sqrt(8*(n_pairs-1-k)+1) - 1) / 2)
             However a cheaper O(1) derivation:
               let the "reverse k" be rk = n_pairs - 1 - k
               i' = floor((sqrt(8*rk + 1) - 1) / 2)
               i  = n - 2 - i'
               j  = k - i*n + i*(i+1)/2 + i + 1
             But let's just do the standard formula. *)
          let i = ref 0 in
          let acc = ref k in
          (* Find which row: row i has (n - 1 - i) entries *)
          while !acc >= n - 1 - !i do
            acc := !acc - (n - 1 - !i);
            i := !i + 1
          done;
          let row = !i in
          let col = row + 1 + !acc in
          let d = Distance.compute_with_config ~config:distance_config
              tree_arr.(row) tree_arr.(col) in
          dist.(row).(col) <- d));
    Domainslib.Task.teardown_pool pool;
    (* Fill lower triangle by symmetry *)
    for i = 0 to n - 1 do
      for j = 0 to i - 1 do
        dist.(i).(j) <- dist.(j).(i)
      done
    done;
    dist

let precompute_distances_parallel_pruned
    ?(num_domains = default_num_domains ())
    ?(distance_config = Distance.default_config)
    ~threshold
    (trees : 'a Tree.t list)
  =
  let n = List.length trees in
  let tree_arr = Array.of_list trees in
  let evs = Array.map tree_arr ~f:Tree.ev in
  let dist = Array.init n ~f:(fun _ -> Array.create ~len:n 0.0) in
  let n_pairs = n * (n - 1) / 2 in
  let num_computed = Atomic.make 0 in
  let num_skipped = Atomic.make 0 in
  match n_pairs with
  | 0 -> (dist, 0, 0)
  | _ ->
    let pool = Domainslib.Task.setup_pool ~num_domains () in
    Domainslib.Task.run pool (fun () ->
      Domainslib.Task.parallel_for pool ~start:0 ~finish:(n_pairs - 1)
        ~body:(fun k ->
          let i = ref 0 in
          let acc = ref k in
          while !acc >= n - 1 - !i do
            acc := !acc - (n - 1 - !i);
            i := !i + 1
          done;
          let row = !i in
          let col = row + 1 + !acc in
          let ev_diff = Float.abs (evs.(row) -. evs.(col)) in
          match Float.( > ) ev_diff threshold with
          | true ->
            Atomic.incr num_skipped;
            dist.(row).(col) <- Float.infinity
          | false ->
            Atomic.incr num_computed;
            let d = Distance.compute_with_config ~config:distance_config
                tree_arr.(row) tree_arr.(col) in
            dist.(row).(col) <- d));
    Domainslib.Task.teardown_pool pool;
    for i = 0 to n - 1 do
      for j = 0 to i - 1 do
        dist.(i).(j) <- dist.(j).(i)
      done
    done;
    (dist, Atomic.get num_computed, Atomic.get num_skipped)

let precompute_distances_parallel_fast
    ?(num_domains = default_num_domains ())
    ?(distance_config = Distance.default_config)
    ~threshold
    (trees : 'a Tree.t list)
  =
  let n = List.length trees in
  let tree_arr = Array.of_list trees in
  let evs = Array.map tree_arr ~f:Tree.ev in
  let dist = Array.init n ~f:(fun _ -> Array.create ~len:n 0.0) in
  let n_pairs = n * (n - 1) / 2 in
  let ev_pruned = Atomic.make 0 in
  let shallow_pruned = Atomic.make 0 in
  let full_computed = Atomic.make 0 in
  match n_pairs with
  | 0 -> (dist, (0, 0, 0))
  | _ ->
    let pool = Domainslib.Task.setup_pool ~num_domains () in
    Domainslib.Task.run pool (fun () ->
      Domainslib.Task.parallel_for pool ~start:0 ~finish:(n_pairs - 1)
        ~body:(fun k ->
          let i = ref 0 in
          let acc = ref k in
          while !acc >= n - 1 - !i do
            acc := !acc - (n - 1 - !i);
            i := !i + 1
          done;
          let row = !i in
          let col = row + 1 + !acc in
          let ev_diff = Float.abs (evs.(row) -. evs.(col)) in
          match Float.( > ) ev_diff threshold with
          | true ->
            Atomic.incr ev_pruned;
            dist.(row).(col) <- Float.infinity
          | false ->
            let d, depth_used =
              Distance.compute_progressive ~config:distance_config ~threshold
                tree_arr.(row) tree_arr.(col)
            in
            (match depth_used < Int.max_value with
             | true -> Atomic.incr shallow_pruned
             | false -> Atomic.incr full_computed);
            dist.(row).(col) <- d));
    Domainslib.Task.teardown_pool pool;
    for i = 0 to n - 1 do
      for j = 0 to i - 1 do
        dist.(i).(j) <- dist.(j).(i)
      done
    done;
    (dist, (Atomic.get ev_pruned, Atomic.get shallow_pruned, Atomic.get full_computed))

let precompute_distances_parallel_memoized
    ?(num_domains = default_num_domains ())
    (trees : 'a Tree.t list)
  =
  let config = Distance.default_config in
  let n = List.length trees in
  let tree_arr = Array.of_list trees in
  let dist = Array.init n ~f:(fun _ -> Array.create ~len:n 0.0) in
  let n_pairs = n * (n - 1) / 2 in
  match n_pairs with
  | 0 -> dist
  | _ ->
    (* Each domain gets its own memo cache to avoid lock contention.
       We use Domain-local storage via a Hashtbl created per-chunk.
       Since parallel_for distributes chunks, each chunk runs on one
       domain and reuses its own local cache. *)
    let pool = Domainslib.Task.setup_pool ~num_domains () in
    Domainslib.Task.run pool (fun () ->
      Domainslib.Task.parallel_for pool ~start:0 ~finish:(n_pairs - 1)
        ~body:(fun k ->
          let i = ref 0 in
          let acc = ref k in
          while !acc >= n - 1 - !i do
            acc := !acc - (n - 1 - !i);
            i := !i + 1
          done;
          let row = !i in
          let col = row + 1 + !acc in
          (* Use the non-memoized path here since the global Memo.cache
             is not thread-safe and per-iteration local caches would not
             benefit from cross-pair sharing.  The key win is parallelism
             over the O(n^2) pairs, not memoization within each pair. *)
          let d = Distance.compute_with_config ~config tree_arr.(row) tree_arr.(col) in
          dist.(row).(col) <- d));
    Domainslib.Task.teardown_pool pool;
    for i = 0 to n - 1 do
      for j = 0 to i - 1 do
        dist.(i).(j) <- dist.(j).(i)
      done
    done;
    dist
