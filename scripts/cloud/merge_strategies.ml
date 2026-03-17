(* merge_strategies.ml -- Standalone strategy merger for distributed CFR.

   This is a reference copy of the merge logic.  The canonical version lives
   in bin/merge_strategies.ml and is built as the rbm-merge-strategies
   executable.  Use that binary for production merges:

     opam exec -- dune exec -- rbm-merge-strategies -o merged.dat w1.dat w2.dat

   This file documents the algorithm for portability.

   -----------------------------------------------------------------------
   Algorithm: Distributed MCCFR strategy merging
   -----------------------------------------------------------------------

   Each MCCFR worker independently trains for N iterations and produces a
   cfr_state containing:

     regret_sum  : (string, float array) Hashtbl.Poly.t
     strategy_sum : (string, float array) Hashtbl.Poly.t

   Both tables map information-set keys (strings) to float arrays whose
   length equals the number of available actions at that info set.

   To merge K workers:
     1. For each info-set key present in ANY worker:
        - Collect the float arrays from all workers that have that key
        - Element-wise average them: merged[i] = sum(worker_k[i]) / K
     2. Missing keys in a worker contribute zeros (equivalent to that
        worker never visiting that info set).
     3. The merged cfr_state is mathematically equivalent to a single
        worker that ran K*N iterations, up to sampling variance.

   This works because regret sums and strategy sums are additive:
   averaging K independent runs of N iterations each produces an unbiased
   estimator of a single run of K*N iterations.

   -----------------------------------------------------------------------
   Serialization format (Marshal, closure-free)
   -----------------------------------------------------------------------

   Files are OCaml Marshal format containing a 4-tuple of association lists:

     ( (string * float array) list    -- P0 regret_sum
     * (string * float array) list    -- P0 strategy_sum
     * (string * float array) list    -- P1 regret_sum
     * (string * float array) list )  -- P1 strategy_sum

   We use association lists instead of Hashtbl.Poly.t to avoid Marshal
   closure compatibility issues.  Core's Hashtbl.Poly.t contains closures
   (the comparison function) whose module hashes differ across executables,
   causing "unknown code module" errors when deserializing between the
   trainer binary and the merger binary.

   The trainer (rbm-train-mccfr-nl) converts hashtables to alists before
   marshaling, and the merger converts them back.

   -----------------------------------------------------------------------
   Usage from the built binary
   -----------------------------------------------------------------------

     # Merge 4 worker outputs:
     opam exec -- dune exec -- rbm-merge-strategies \
       -o merged_strategy.dat \
       worker_0.dat worker_1.dat worker_2.dat worker_3.dat

     # Then convert to averaged strategy for evaluation:
     # The merged file can be loaded by any tool that reads the same
     # alist-based Marshal format.
*)

(* The actual implementation is in bin/merge_strategies.ml.
   Key function:

   let merge_tables tables =
     let n = Float.of_int (List.length tables) in
     let result = Hashtbl.Poly.create () in
     List.iter tables ~f:(fun tbl ->
       Hashtbl.iteri tbl ~f:(fun ~key ~data ->
         match Hashtbl.find result key with
         | None -> Hashtbl.set result ~key ~data:(Array.copy data)
         | Some existing ->
           Array.iteri data ~f:(fun i v ->
             existing.(i) <- existing.(i) +. v)));
     Hashtbl.iteri result ~f:(fun ~key:_ ~data ->
       Array.iteri data ~f:(fun i v -> data.(i) <- v /. n));
     result
*)
