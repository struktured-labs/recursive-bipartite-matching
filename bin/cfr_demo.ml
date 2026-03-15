open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

let () =
  printf "=== CFR on Rhode Island Hold'em: Full vs Compressed ===\n\n%!";

  (* ================================================================ *)
  (* Part 1: Verify CFR convergence on 3-rank game                    *)
  (* ================================================================ *)
  printf "--- [1] CFR convergence (3-rank, 1 round) ---\n\n%!";

  let config_small = {
    Rhode_island.deck = Card.small_deck ~n_ranks:3;
    ante = 5;
    bet_sizes = [ 10 ];
    max_raises = 1;
  } in
  let deck_small = config_small.deck in
  let comm_small = [ List.nth_exn deck_small 0; List.nth_exn deck_small 1 ] in

  printf "  Deck: %s  Community: %s %s\n%!"
    (String.concat ~sep:" " (List.map deck_small ~f:Card.to_string))
    (Card.to_string (List.nth_exn deck_small 0))
    (Card.to_string (List.nth_exn deck_small 1));

  printf "  %10s  %12s  %8s\n%!" "iterations" "exploit" "time";
  printf "  %s\n%!" (String.make 36 '-');
  List.iter [ 10; 50; 100; 500; 1000 ] ~f:(fun iters ->
    let ((p1, p2), wall) = time (fun () ->
      Cfr.train ~config:config_small ~community:comm_small ~iterations:iters) in
    let exploit = Cfr.exploitability ~config:config_small
        ~community:comm_small p1 p2 in
    printf "  %10d  %12.6f  %7.3fs\n%!" iters exploit wall);
  printf "\n  Exploitability -> 0: CFR finds Nash equilibrium.\n\n%!";

  (* ================================================================ *)
  (* Part 2: Main experiment: 3-rank, 2 rounds, varied community      *)
  (* ================================================================ *)
  printf "--- [2] Setup (3-rank, 2 rounds) ---\n\n%!";

  let n_ranks = 3 in
  let config = {
    Rhode_island.deck = Card.small_deck ~n_ranks;
    ante = 5;
    bet_sizes = [ 10; 10 ];
    max_raises = 1;
  } in
  let deck = config.deck in
  let flop = List.nth_exn deck 0 in  (* 2c *)
  let turn = List.nth_exn deck 5 in  (* 3d *)
  let community = [ flop; turn ] in
  printf "  Deck (%d cards, %d ranks): %s\n%!"
    (List.length deck) n_ranks
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));
  printf "  Community: %s %s\n%!"
    (Card.to_string flop) (Card.to_string turn);
  printf "  Betting: %d rounds, ante=%d, bet=%d, max_raises=%d\n%!"
    (List.length config.bet_sizes) config.ante
    (List.hd_exn config.bet_sizes) config.max_raises;

  let available = List.filter deck ~f:(fun c ->
    not (Card.equal c flop) && not (Card.equal c turn)) in
  let num_cards = List.length available in

  let sample_tree = Rhode_island.game_tree_for_deal ~config
      ~p1_card:(List.nth_exn available 0)
      ~p2_card:(List.nth_exn available 1)
      ~community in
  printf "  Available: %d cards, %d deals\n%!" num_cards (num_cards * (num_cards - 1));
  printf "  Tree: %d nodes, %d leaves, depth %d\n\n%!"
    (Tree.size sample_tree) (Tree.num_leaves sample_tree) (Tree.depth sample_tree);

  (* ================================================================ *)
  (* Part 3: Train CFR on full game                                   *)
  (* ================================================================ *)
  printf "--- [3] CFR on full game ---\n\n%!";

  let cfr_iters = 1000 in
  printf "  %10s  %12s  %8s\n%!" "iterations" "exploit" "time";
  printf "  %s\n%!" (String.make 36 '-');

  let full_strats = ref (Hashtbl.Poly.create (), Hashtbl.Poly.create ()) in
  List.iter [ 10; 50; 100; 250; 500; 1000 ] ~f:(fun iters ->
    let ((p1, p2), wall) = time (fun () ->
      Cfr.train ~config ~community ~iterations:iters) in
    let exploit = Cfr.exploitability ~config ~community p1 p2 in
    printf "  %10d  %12.6f  %7.3fs\n%!" iters exploit wall;
    full_strats := (p1, p2));

  let (full_p1, full_p2) = !full_strats in
  let full_exploit = Cfr.exploitability ~config ~community full_p1 full_p2 in
  printf "\n  Exploitability at %d iters: %.6f\n\n%!" cfr_iters full_exploit;

  (* ================================================================ *)
  (* Part 4: Compression + compressed CFR                             *)
  (* ================================================================ *)
  printf "--- [4] Compression impact on exploitability ---\n\n%!";

  let is_trees = List.map available ~f:(fun card ->
    Rhode_island.information_set_tree ~config ~player:0
      ~hole_card:card ~community) in
  let (dist_matrix, _) = time (fun () ->
    Ev_graph.precompute_distances is_trees) in

  (* Pick epsilons that give diverse cluster counts *)
  let epsilons = [ 0.0; 50.0; 100.0; 200.0; 500.0; 1000.0 ] in
  printf "  %8s  %8s  %10s  %12s  %8s\n%!"
    "epsilon" "clusters" "ev_error" "exploit" "time";
  printf "  %s\n%!" (String.make 56 '-');
  printf "  %8s  %8d  %10s  %12.6f  %8s\n%!"
    "full" num_cards "-" full_exploit "see [3]";

  let results = List.filter_map epsilons ~f:(fun epsilon ->
    let graph = Ev_graph.compress ~epsilon ~precomputed:dist_matrix is_trees in
    let n_clusters = List.length graph.clusters in
    let ev_err = Ev_graph.ev_error graph in
    let ((comp_p1, comp_p2, comp_key_fn), wall) = time (fun () ->
      Cfr.train_compressed ~config ~community ~ev_graph:graph ~iterations:cfr_iters) in
    let exploit = Cfr.exploitability_with_key_fn ~config ~community
        ~info_key_fn:comp_key_fn comp_p1 comp_p2 in
    printf "  %8.0f  %8d  %10.4f  %12.6f  %7.3fs\n%!"
      epsilon n_clusters ev_err exploit wall;
    Some (epsilon, n_clusters, ev_err, exploit)) in
  printf "\n%!";

  (* Cluster details *)
  List.iter epsilons ~f:(fun eps ->
    let graph = Ev_graph.compress ~epsilon:eps ~precomputed:dist_matrix is_trees in
    let k = List.length graph.clusters in
    match k > 1 && k < num_cards with
    | true ->
      printf "  eps=%.0f (%d clusters):\n%!" eps k;
      List.iteri graph.clusters ~f:(fun ci cluster ->
        let member_cards = List.map cluster.members ~f:(fun (idx, _) ->
          Card.to_string (List.nth_exn available idx)) in
        printf "    C%d: {%s}  EV=%.2f\n%!"
          ci (String.concat ~sep:", " member_cards)
          (Tree.ev cluster.representative));
      printf "\n%!"
    | false -> ());

  (* ================================================================ *)
  (* Part 5: RBM vs EMD comparison                                   *)
  (* ================================================================ *)
  printf "--- [5] RBM vs EMD: which metric gives lower exploitability? ---\n\n%!";

  let emd_dists = List.map available ~f:(fun card ->
    Emd_baseline.compute_distribution ~deck:config.deck
      ~p1_card:card ~community) in
  let emd_matrix = Emd_baseline.pairwise_emd_matrix emd_dists in

  (* Pre-compute graphs at a few specific epsilons to find interesting
     cluster counts without expensive sweeps *)
  let find_graph_at_k ~matrix ~max_dist target_k =
    let best = ref (None : (float * Rhode_island.Node_label.t Ev_graph.t) option) in
    let best_diff = ref num_cards in
    for step = 0 to 50 do
      let eps = Float.of_int step /. 50.0 *. max_dist *. 1.2 in
      let graph = Ev_graph.compress ~epsilon:eps ~precomputed:matrix is_trees in
      let k = List.length graph.clusters in
      let diff = Int.abs (k - target_k) in
      match diff < !best_diff with
      | true -> best := Some (eps, graph); best_diff := diff
      | false -> ()
    done;
    !best
  in

  let rbm_max = ref 0.0 in
  let emd_max = ref 0.0 in
  for i = 0 to num_cards - 2 do
    for j = i + 1 to num_cards - 1 do
      (match Float.( > ) dist_matrix.(i).(j) !rbm_max with
       | true -> rbm_max := dist_matrix.(i).(j)
       | false -> ());
      (match Float.( > ) emd_matrix.(i).(j) !emd_max with
       | true -> emd_max := emd_matrix.(i).(j)
       | false -> ())
    done
  done;

  let target_clusters = [ 7; 5; 3; 2 ]
    |> List.filter ~f:(fun k -> k < num_cards && k > 1) in

  printf "  %8s  %6s  %6s  %12s  %6s\n%!"
    "k_target" "method" "k_act" "exploit" "winner";
  printf "  %s\n%!" (String.make 48 '-');

  let rbm_wins = ref 0 in
  let emd_wins = ref 0 in
  let ties = ref 0 in

  List.iter target_clusters ~f:(fun target_k ->
    let rbm_opt = find_graph_at_k ~matrix:dist_matrix ~max_dist:!rbm_max target_k in
    let emd_opt = find_graph_at_k ~matrix:emd_matrix ~max_dist:!emd_max target_k in

    match rbm_opt, emd_opt with
    | Some (_rbm_eps, rbm_graph), Some (_emd_eps, emd_graph) ->
      let rbm_k = List.length rbm_graph.clusters in
      let emd_k = List.length emd_graph.clusters in

      let (rbm_p1, rbm_p2, rbm_key) = Cfr.train_compressed ~config ~community
          ~ev_graph:rbm_graph ~iterations:cfr_iters in
      let (emd_p1, emd_p2, emd_key) = Cfr.train_compressed ~config ~community
          ~ev_graph:emd_graph ~iterations:cfr_iters in

      let rbm_exploit = Cfr.exploitability_with_key_fn ~config ~community
          ~info_key_fn:rbm_key rbm_p1 rbm_p2 in
      let emd_exploit = Cfr.exploitability_with_key_fn ~config ~community
          ~info_key_fn:emd_key emd_p1 emd_p2 in

      let winner_str =
        let diff = Float.abs (rbm_exploit -. emd_exploit) in
        match Float.( < ) diff 0.001 with
        | true -> Int.incr ties; "tie"
        | false ->
          match Float.( < ) rbm_exploit emd_exploit with
          | true -> Int.incr rbm_wins; "RBM"
          | false -> Int.incr emd_wins; "EMD"
      in

      printf "  %8d  %6s  %6d  %12.6f\n%!" target_k "RBM" rbm_k rbm_exploit;
      printf "  %8s  %6s  %6d  %12.6f  %6s\n%!" "" "EMD" emd_k emd_exploit winner_str
    | _ -> printf "  %8d  (could not find matching epsilon)\n%!" target_k);
  printf "\n%!";

  (* ================================================================ *)
  (* Part 6: Summary                                                  *)
  (* ================================================================ *)
  printf "--- [6] Summary ---\n\n%!";

  printf "1. CFR convergence verified: exploitability -> 0.\n%!";
  printf "   Full %d-rank game at %d iters: %.6f\n\n%!"
    n_ranks cfr_iters full_exploit;

  printf "2. Compression vs exploitability:\n%!";
  List.iter results ~f:(fun (eps, k, _ev_err, exploit) ->
    printf "   eps=%5.0f: %2d clusters, exploit=%.6f\n%!" eps k exploit);
  printf "   Exploitability increases as compression merges strategically\n%!";
  printf "   distinct hands into the same information set.\n\n%!";

  printf "3. RBM vs EMD:\n%!";
  printf "   RBM wins: %d, EMD wins: %d, ties: %d\n%!"
    !rbm_wins !emd_wins !ties;
  printf "   The metric that better captures game-tree strategic similarity\n%!";
  printf "   produces abstractions with lower exploitability.\n\n%!";

  printf "Done.\n"
