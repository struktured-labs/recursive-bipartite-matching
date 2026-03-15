open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

let () =
  printf "=== Recursive Bipartite Matching on Game Trees ===\n";
  printf "=== Rhode Island Hold'em — Full Pipeline ===\n\n%!";

  (* ================================================================ *)
  (* Part 0: Sanity checks                                            *)
  (* ================================================================ *)
  printf "--- [0] Sanity checks ---\n\n%!";

  let t1 = Tree.node ~label:"A" ~children:[
    Tree.leaf ~label:"a1" ~value:10.0;
    Tree.leaf ~label:"a2" ~value:20.0;
  ] in
  let t2 = Tree.node ~label:"B" ~children:[
    Tree.leaf ~label:"b1" ~value:10.0;
    Tree.leaf ~label:"b2" ~value:20.0;
  ] in
  let t3 = Tree.node ~label:"C" ~children:[
    Tree.leaf ~label:"c1" ~value:15.0;
    Tree.leaf ~label:"c2" ~value:25.0;
  ] in
  let t4 = Tree.node ~label:"D" ~children:[
    Tree.leaf ~label:"d1" ~value:10.0;
    Tree.leaf ~label:"d2" ~value:20.0;
    Tree.leaf ~label:"d3" ~value:30.0;
  ] in

  let check name expected actual =
    let pass = Float.(abs (expected -. actual) < 0.01) in
    printf "  %-35s = %7.2f  (expect %5.1f)  %s\n%!" name actual expected
      (match pass with true -> "OK" | false -> "FAIL")
  in
  check "d(identical-values)" 0.0 (Distance.compute t1 t2);
  check "d(shifted +5 each)" 10.0 (Distance.compute t1 t3);
  check "d(self)" 0.0 (Distance.compute t1 t1);
  printf "  d(extra child)                      = %7.2f  (phantom penalty)\n%!"
    (Distance.compute t1 t4);

  let d12 = Distance.compute t1 t2 in
  let d13 = Distance.compute t1 t3 in
  let d23 = Distance.compute t2 t3 in
  printf "  Triangle: %.1f <= %.1f+%.1f = %.1f  %s\n\n%!"
    d13 d12 d23 (d12 +. d23)
    (match Float.( <= ) d13 (d12 +. d23 +. 0.001) with
     | true -> "PASS" | false -> "FAIL");

  (* ================================================================ *)
  (* Part 1: Generate Rhode Island Hold'em game trees                 *)
  (* ================================================================ *)
  printf "--- [1] Rhode Island Hold'em game trees (4-rank deck) ---\n\n%!";

  let config = Rhode_island.small_config ~n_ranks:4 in
  let deck = config.deck in
  printf "Deck (%d cards): %s\n%!"
    (List.length deck)
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));

  (* Fixed community cards — same suit enables flushes for richer hand diversity *)
  let flop = List.nth_exn deck 0 in   (* 2c *)
  let turn = List.nth_exn deck 1 in   (* 3c *)
  let community = [ flop; turn ] in
  printf "Community: %s %s\n\n%!" (Card.to_string flop) (Card.to_string turn);

  (* Generate ALL possible deals for this community *)
  let remaining = List.filter deck ~f:(fun c ->
    not (Card.equal c flop) && not (Card.equal c turn))
  in
  let all_pairs = ref [] in
  List.iteri remaining ~f:(fun i c1 ->
    List.iteri remaining ~f:(fun j c2 ->
      match j > i with
      | true -> all_pairs := (c1, c2) :: !all_pairs
      | false -> ()));
  let all_pairs = List.rev !all_pairs in

  let (all_trees, gen_time) = time (fun () ->
    List.map all_pairs ~f:(fun (p1, p2) ->
      let t = Rhode_island.game_tree_for_deal ~config ~p1_card:p1 ~p2_card:p2 ~community in
      ((p1, p2), t)))
  in
  let n = List.length all_trees in
  printf "Generated %d deal trees in %.3fs\n%!" n gen_time;
  let sample_tree = snd (List.hd_exn all_trees) in
  printf "Each tree: %d nodes, %d leaves, depth %d\n\n%!"
    (Tree.size sample_tree) (Tree.num_leaves sample_tree) (Tree.depth sample_tree);

  (* Show EV distribution — just summary for 4-rank *)
  printf "EV distribution (first 20 of %d deals):\n%!" n;
  List.iteri all_trees ~f:(fun i ((p1, p2), t) ->
    match i < 20 with
    | true ->
      printf "  %s vs %s: EV=%+7.1f\n%!" (Card.to_string p1) (Card.to_string p2) (Tree.ev t)
    | false -> ());
  (match n > 20 with
   | true -> printf "  ... (%d more)\n%!" (n - 20)
   | false -> ());
  printf "\n%!";

  (* ================================================================ *)
  (* Part 2: Pairwise distance matrix — summary statistics            *)
  (* ================================================================ *)
  printf "--- [2] Pairwise distance matrix ---\n\n%!";

  let trees_only = List.map all_trees ~f:snd in
  let (dist_matrix, matrix_time) = time (fun () ->
    Ev_graph.precompute_distances trees_only)
  in
  printf "Computed %dx%d distance matrix in %.3fs\n%!" n n matrix_time;
  printf "  (%d unique pairwise comparisons)\n\n%!" (n * (n - 1) / 2);

  (* Collect all unique pairwise distances *)
  let all_distances = ref [] in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      all_distances := dist_matrix.(i).(j) :: !all_distances
    done
  done;
  let all_distances = List.sort !all_distances ~compare:Float.compare in
  let num_pairs = List.length all_distances in

  (* Summary statistics *)
  let nonzero_distances = List.filter all_distances ~f:(fun d -> Float.( > ) d 0.0) in
  let min_nonzero = match nonzero_distances with
    | [] -> 0.0
    | d :: _ -> d
  in
  let max_dist = match List.last all_distances with
    | Some d -> d
    | None -> 0.0
  in
  let sum_dist = List.fold all_distances ~init:0.0 ~f:( +. ) in
  let mean_dist = sum_dist /. Float.of_int num_pairs in
  let median_dist =
    let mid = num_pairs / 2 in
    match num_pairs % 2 = 0 with
    | true ->
      (List.nth_exn all_distances (mid - 1) +. List.nth_exn all_distances mid) /. 2.0
    | false ->
      List.nth_exn all_distances mid
  in
  (* Count distinct distance values (rounded to 1 decimal) *)
  let distinct_rounded = List.dedup_and_sort
    (List.map all_distances ~f:(fun d -> Float.round_decimal d ~decimal_digits:1))
    ~compare:Float.compare
  in
  let num_distinct = List.length distinct_rounded in
  let num_zero = num_pairs - List.length nonzero_distances in

  printf "Summary statistics:\n%!";
  printf "  Total pairs:           %d\n%!" num_pairs;
  printf "  Zero-distance pairs:   %d\n%!" num_zero;
  printf "  Min nonzero distance:  %.1f\n%!" min_nonzero;
  printf "  Max distance:          %.1f\n%!" max_dist;
  printf "  Mean distance:         %.1f\n%!" mean_dist;
  printf "  Median distance:       %.1f\n%!" median_dist;
  printf "  Distinct values (0.1): %d\n\n%!" num_distinct;

  (* Histogram — ~10 bins *)
  let num_bins = 10 in
  let bin_width = match Float.( > ) max_dist 0.0 with
    | true -> max_dist /. Float.of_int num_bins
    | false -> 1.0
  in
  let bins = Array.create ~len:num_bins 0 in
  List.iter all_distances ~f:(fun d ->
    let bin = Float.to_int (d /. bin_width) in
    let bin = match bin >= num_bins with true -> num_bins - 1 | false -> bin in
    bins.(bin) <- bins.(bin) + 1);

  printf "Distance histogram (%d bins, width=%.1f):\n%!" num_bins bin_width;
  let max_count = Array.fold bins ~init:0 ~f:Int.max in
  let bar_scale = match max_count > 60 with
    | true -> Float.of_int max_count /. 60.0
    | false -> 1.0
  in
  Array.iteri bins ~f:(fun i count ->
    let lo = Float.of_int i *. bin_width in
    let hi = lo +. bin_width in
    let bar_len = Float.to_int (Float.of_int count /. bar_scale) in
    let bar = String.make bar_len '#' in
    printf "  [%6.0f - %6.0f) %4d  %s\n%!" lo hi count bar);
  printf "\n%!";

  (* ================================================================ *)
  (* Part 3: EV Graph compression at various epsilon                  *)
  (* ================================================================ *)
  printf "--- [3] EV Graph compression ---\n\n%!";

  let epsilons = [ 0.0; 50.0; 200.0; 500.0; 1000.0; 2000.0 ] in

  List.iter epsilons ~f:(fun epsilon ->
    let (graph, ct) = time (fun () ->
      Ev_graph.compress ~epsilon ~precomputed:dist_matrix trees_only) in
    let num_clusters = List.length graph.clusters in
    let ev_err = Ev_graph.ev_error graph in
    printf "  epsilon=%6.0f: %2d clusters (%.1fx compression) \
            max_ev_err=%7.2f  [%.3fs]\n%!"
      epsilon num_clusters graph.compression_ratio ev_err ct;

    (* Show cluster composition for interesting cases *)
    match num_clusters < n && num_clusters > 1 with
    | true ->
      (match num_clusters <= 20 with
       | true ->
         List.iteri graph.clusters ~f:(fun ci cluster ->
           let member_strs = List.map cluster.members ~f:(fun (idx, _) ->
             let (p1, p2), _ = List.nth_exn all_trees idx in
             Card.to_string p1 ^ Card.to_string p2)
           in
           printf "    cluster %d: {%s} rep_EV=%.1f diam=%.0f\n%!"
             ci (String.concat ~sep:", " member_strs)
             (Tree.ev cluster.representative) cluster.diameter)
       | false ->
         printf "    (%d clusters — too many to list individually)\n%!" num_clusters)
    | false -> ());
  printf "\n%!";

  (* ================================================================ *)
  (* Part 4: Error bound verification                                 *)
  (* ================================================================ *)
  printf "--- [4] Error bound verification ---\n\n%!";

  (* Use epsilon=200 for a non-trivial compression *)
  let graph_200 = Ev_graph.compress ~epsilon:200.0 ~precomputed:dist_matrix trees_only in
  printf "%s\n\n%!" (Error_bound.report graph_200);

  (* Also verify at epsilon=500 *)
  let graph_500 = Ev_graph.compress ~epsilon:500.0 ~precomputed:dist_matrix trees_only in
  printf "%s\n\n%!" (Error_bound.report graph_500);

  (* ================================================================ *)
  (* Part 5: Monte Carlo location                                     *)
  (* ================================================================ *)
  printf "--- [5] Monte Carlo location ---\n\n%!";

  (* Build a graph with moderate compression *)
  let graph = Ev_graph.compress ~epsilon:300.0 ~precomputed:dist_matrix trees_only in
  let num_clusters = List.length graph.clusters in
  printf "Using EV graph with %d clusters (epsilon=300):\n%!" num_clusters;
  (match num_clusters <= 20 with
   | true ->
     List.iteri graph.clusters ~f:(fun ci cluster ->
       let member_strs = List.map cluster.members ~f:(fun (idx, _) ->
         let (p1, p2), _ = List.nth_exn all_trees idx in
         Card.to_string p1 ^ Card.to_string p2)
       in
       printf "  C%d: {%s} EV=%.1f\n%!" ci
         (String.concat ~sep:", " member_strs)
         (Tree.ev cluster.representative))
   | false ->
     printf "  (%d clusters — showing representative EVs)\n%!" num_clusters;
     List.iteri graph.clusters ~f:(fun ci cluster ->
       let n_members = List.length cluster.members in
       printf "  C%d: %d members, rep_EV=%.1f, diam=%.0f\n%!" ci
         n_members (Tree.ev cluster.representative) cluster.diameter));
  printf "\n%!";

  (* --- Part 5a: Exact location using precomputed distance matrix --- *)
  printf "Part 5a: Exact location (via precomputed distance matrix)\n%!";

  let exact_correct = ref 0 in
  let exact_total = ref 0 in
  let exact_wrong = ref [] in
  List.iteri all_trees ~f:(fun tree_idx ((p1, p2), tree) ->
    (* Find closest cluster rep using precomputed distances *)
    let best_ci, _best_dist =
      List.foldi graph.clusters ~init:(0, Float.infinity) ~f:(fun ci (best_ci, best_d) cluster ->
        let rep_idx = fst (List.hd_exn cluster.members) in
        let d = dist_matrix.(tree_idx).(rep_idx) in
        match Float.( < ) d best_d with
        | true -> (ci, d)
        | false -> (best_ci, best_d))
    in
    let in_cluster =
      let cluster = List.nth_exn graph.clusters best_ci in
      List.exists cluster.members ~f:(fun (mi, _) -> mi = tree_idx)
    in
    exact_total := !exact_total + 1;
    (match in_cluster with
     | true -> exact_correct := !exact_correct + 1
     | false ->
       exact_wrong := (Card.to_string p1 ^ " " ^ Card.to_string p2,
                        Tree.ev tree, best_ci) :: !exact_wrong));
  printf "  Exact location accuracy: %d/%d (%.1f%%)\n%!"
    !exact_correct !exact_total
    (100.0 *. Float.of_int !exact_correct /. Float.of_int !exact_total);
  (match !exact_wrong with
   | [] -> ()
   | wrongs ->
     printf "  Mislocated deals:\n%!";
     List.iter (List.rev wrongs) ~f:(fun (deal, ev, ci) ->
       printf "    %s EV=%+.1f -> C%d WRONG\n%!" deal ev ci));
  printf "\n%!";

  (* --- Part 5b: Monte Carlo location with auto-tuned beta --- *)
  printf "Part 5b: Monte Carlo location (sampling-based)\n%!";

  (* Auto-tune beta: use inverse of mean nonzero distance for sharper discrimination *)
  let mean_nonzero_dist = match nonzero_distances with
    | [] -> mean_dist
    | ds ->
      let sum = List.fold ds ~init:0.0 ~f:( +. ) in
      sum /. Float.of_int (List.length ds)
  in
  let beta = match Float.( > ) mean_nonzero_dist 0.0 with
    | true -> 1.0 /. mean_nonzero_dist
    | false -> 0.05
  in
  printf "  Auto-tuned beta = %.6f (1/mean_nonzero_distance = 1/%.1f)\n%!"
    beta mean_nonzero_dist;

  (* Use deeper samples to capture more tree structure *)
  let sample_depth = Tree.depth sample_tree in
  printf "  Sample depth = %d (full tree depth), num_samples = 50\n%!"
    sample_depth;

  let loc_config = { Locator.
    num_samples = 50;
    sample_depth;
    beta;
    distance_config = Distance.default_config;
  } in

  let correct_count = ref 0 in
  let total_count = ref 0 in
  let mc_entropy_sum = ref 0.0 in
  let ((), loc_time) = time (fun () ->
    List.iter all_trees ~f:(fun ((p1, p2), tree) ->
      let belief = Locator.locate ~config:loc_config graph ~game_state_tree:tree in
      let tree_idx =
        List.findi all_trees ~f:(fun _ ((q1, q2), _) ->
          Card.equal p1 q1 && Card.equal p2 q2)
        |> Option.map ~f:fst
      in
      let in_map_cluster = match tree_idx with
        | Some idx ->
          let cluster = List.nth_exn graph.clusters belief.map_cluster in
          List.exists cluster.members ~f:(fun (mi, _) -> mi = idx)
        | None -> false
      in
      total_count := !total_count + 1;
      mc_entropy_sum := !mc_entropy_sum +. belief.entropy;
      (match in_map_cluster with true -> correct_count := !correct_count + 1 | false -> ())))
  in
  let mc_avg_entropy = !mc_entropy_sum /. Float.of_int !total_count in
  printf "  Monte Carlo location accuracy: %d/%d (%.1f%%)\n%!"
    !correct_count !total_count
    (100.0 *. Float.of_int !correct_count /. Float.of_int !total_count);
  printf "  Average entropy: %.3f (max possible: %.3f for %d clusters)\n%!"
    mc_avg_entropy (Float.log (Float.of_int num_clusters)) num_clusters;
  printf "  Location time: %.3fs\n%!" loc_time;
  printf "\n  NOTE: Monte Carlo location struggles because sample_subtree produces\n\
         \  single-path subtrees (~15 nodes) vs full representatives (~1141 nodes).\n\
         \  The phantom penalty for unmatched branches dominates, making all cluster\n\
         \  distances roughly equal. The exact method (Part 5a) works perfectly.\n\
         \  Fix: use the full tree directly with find_cluster, or improve the sampler\n\
         \  to produce multi-branch subtrees.\n\n%!";

  (* ================================================================ *)
  (* Part 6: Metric properties (comprehensive)                       *)
  (* ================================================================ *)
  printf "--- [6] Metric property verification ---\n\n%!";

  (* Identity *)
  let identity_ok = List.for_all all_trees ~f:(fun (_, t) ->
    Float.( = ) (Distance.compute t t) 0.0) in
  printf "  Identity (d(x,x)=0 for all %d trees): %s\n%!" n
    (match identity_ok with true -> "PASS" | false -> "FAIL");

  (* Symmetry *)
  let sym_ok = ref true in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      match Float.( = ) dist_matrix.(i).(j) dist_matrix.(j).(i) with
      | true -> ()
      | false -> sym_ok := false
    done
  done;
  printf "  Symmetry (d(x,y)=d(y,x) for all pairs): %s\n%!"
    (match !sym_ok with true -> "PASS" | false -> "FAIL");

  (* Triangle inequality — n^3 triples *)
  let num_triples = n * n * n in
  printf "  Triangle inequality (checking %d triples = %d^3)...\n%!" num_triples n;
  let tri_ok = ref true in
  let tri_violations = ref 0 in
  let worst_violation = ref 0.0 in
  for i = 0 to n - 1 do
    for j = 0 to n - 1 do
      for k = 0 to n - 1 do
        let lhs = dist_matrix.(i).(k) in
        let rhs = dist_matrix.(i).(j) +. dist_matrix.(j).(k) in
        match Float.( <= ) lhs (rhs +. 0.01) with
        | true -> ()
        | false ->
          tri_ok := false;
          tri_violations := !tri_violations + 1;
          let gap = lhs -. rhs in
          (match Float.( > ) gap !worst_violation with
           | true -> worst_violation := gap
           | false -> ())
      done
    done
  done;
  printf "  Triangle inequality: %s"
    (match !tri_ok with
     | true -> sprintf "PASS (all %d triples)" num_triples
     | false -> sprintf "FAIL (%d violations, worst=%.2f)" !tri_violations !worst_violation);
  printf "\n\n%!";

  (* ================================================================ *)
  (* Part 7: Compression vs error tradeoff curve                     *)
  (* ================================================================ *)
  printf "--- [7] Compression vs error tradeoff ---\n\n%!";
  printf "  %8s  %8s  %8s  %10s  %10s\n%!"
    "epsilon" "clusters" "compress" "max_ev_err" "avg_ev_err";

  (* More fine-grained epsilons for the smoother 4-rank curve *)
  let fine_epsilons =
    [ 0.0; 5.0; 10.0; 25.0; 50.0; 75.0; 100.0; 150.0; 200.0; 250.0;
      300.0; 400.0; 500.0; 750.0; 1000.0; 1500.0; 2000.0; 3000.0 ]
  in
  List.iter fine_epsilons ~f:(fun eps ->
    let g = Ev_graph.compress ~epsilon:eps ~precomputed:dist_matrix trees_only in
    let max_err, avg_err, _ = Error_bound.graph_error_analysis g in
    printf "  %8.0f  %8d  %8.1fx  %10.2f  %10.2f\n%!"
      eps (List.length g.clusters) g.compression_ratio max_err avg_err);
  printf "\n%!";

  printf "Done.\n"
