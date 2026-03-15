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
  printf "--- [1] Rhode Island Hold'em game trees (3-rank deck) ---\n\n%!";

  let config = Rhode_island.small_config ~n_ranks:3 in
  let deck = config.deck in
  printf "Deck (%d cards): %s\n%!"
    (List.length deck)
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));

  (* Fixed community cards *)
  let flop = List.nth_exn deck 4 in   (* 3d *)
  let turn = List.nth_exn deck 8 in   (* 4h *)
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

  (* Show EV distribution *)
  printf "EV distribution:\n%!";
  List.iter all_trees ~f:(fun ((p1, p2), t) ->
    printf "  %s vs %s: EV=%+7.1f\n%!" (Card.to_string p1) (Card.to_string p2) (Tree.ev t));
  printf "\n%!";

  (* ================================================================ *)
  (* Part 2: Pairwise distance matrix                                 *)
  (* ================================================================ *)
  printf "--- [2] Pairwise distance matrix ---\n\n%!";

  printf "          ";
  List.iter all_trees ~f:(fun ((p1, p2), _) ->
    printf "%6s" (Card.to_string p1 ^ Card.to_string p2));
  printf "\n%!";

  let trees_only = List.map all_trees ~f:snd in
  let (dist_matrix, matrix_time) = time (fun () ->
    Ev_graph.precompute_distances trees_only)
  in

  List.iteri all_trees ~f:(fun i ((p1i, p2i), _) ->
    printf "%4s%2s" (Card.to_string p1i) (Card.to_string p2i);
    Array.iteri dist_matrix.(i) ~f:(fun j d ->
      match i <= j with
      | true -> printf "%6.0f" d
      | false -> printf "     .");
    printf "\n%!");
  printf "Time: %.3fs\n\n%!" matrix_time;

  (* ================================================================ *)
  (* Part 3: EV Graph compression at various epsilon                  *)
  (* ================================================================ *)
  printf "--- [3] EV Graph compression ---\n\n%!";

  let epsilons = [ 0.0; 50.0; 200.0; 500.0; 1000.0 ] in

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
      List.iteri graph.clusters ~f:(fun ci cluster ->
        let member_strs = List.map cluster.members ~f:(fun (idx, _) ->
          let (p1, p2), _ = List.nth_exn all_trees idx in
          Card.to_string p1 ^ Card.to_string p2)
        in
        printf "    cluster %d: {%s} rep_EV=%.1f diam=%.0f\n%!"
          ci (String.concat ~sep:", " member_strs)
          (Tree.ev cluster.representative) cluster.diameter)
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
  printf "Using EV graph with %d clusters (epsilon=300):\n%!"
    (List.length graph.clusters);
  List.iteri graph.clusters ~f:(fun ci cluster ->
    let member_strs = List.map cluster.members ~f:(fun (idx, _) ->
      let (p1, p2), _ = List.nth_exn all_trees idx in
      Card.to_string p1 ^ Card.to_string p2)
    in
    printf "  C%d: {%s} EV=%.1f\n%!" ci
      (String.concat ~sep:", " member_strs)
      (Tree.ev cluster.representative));
  printf "\n%!";

  (* Test location for each original tree *)
  let loc_config = { Locator.
    num_samples = 30;
    sample_depth = 3;
    beta = 0.05;
    distance_config = Distance.default_config;
  } in

  printf "Locating each original tree in the EV graph:\n%!";
  printf "  %-10s  %-6s  %-8s  %-8s  %-8s\n%!"
    "Deal" "EV" "MAP_C" "MAP_prob" "Entropy";

  let ((), loc_time) = time (fun () ->
    List.iter all_trees ~f:(fun ((p1, p2), tree) ->
      let belief = Locator.locate ~config:loc_config graph ~game_state_tree:tree in
      printf "  %-10s  %+5.1f  C%-7d  %6.1f%%  %8.3f\n%!"
        (Card.to_string p1 ^ " " ^ Card.to_string p2)
        (Tree.ev tree)
        belief.map_cluster
        (belief.map_probability *. 100.0)
        belief.entropy))
  in
  printf "Location time: %.3fs\n\n%!" loc_time;

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

  (* Triangle inequality *)
  let tri_ok = ref true in
  let tri_violations = ref 0 in
  for i = 0 to n - 1 do
    for j = 0 to n - 1 do
      for k = 0 to n - 1 do
        match Float.( <= ) dist_matrix.(i).(k) (dist_matrix.(i).(j) +. dist_matrix.(j).(k) +. 0.01) with
        | true -> ()
        | false -> tri_ok := false; tri_violations := !tri_violations + 1
      done
    done
  done;
  printf "  Triangle inequality (all %d triples): %s"
    (n * n * n)
    (match !tri_ok with true -> "PASS" | false -> sprintf "FAIL (%d violations)" !tri_violations);
  printf "\n\n%!";

  (* ================================================================ *)
  (* Part 7: Compression vs error tradeoff curve                     *)
  (* ================================================================ *)
  printf "--- [7] Compression vs error tradeoff ---\n\n%!";
  printf "  %8s  %8s  %8s  %10s  %10s\n%!"
    "epsilon" "clusters" "compress" "max_ev_err" "avg_ev_err";

  let fine_epsilons =
    [ 0.0; 10.0; 25.0; 50.0; 100.0; 150.0; 200.0; 300.0; 500.0; 750.0; 1000.0 ]
  in
  List.iter fine_epsilons ~f:(fun eps ->
    let g = Ev_graph.compress ~epsilon:eps ~precomputed:dist_matrix trees_only in
    let max_err, avg_err, _ = Error_bound.graph_error_analysis g in
    printf "  %8.0f  %8d  %8.1fx  %10.2f  %10.2f\n%!"
      eps (List.length g.clusters) g.compression_ratio max_err avg_err);
  printf "\n%!";

  printf "Done.\n"
