open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

let print_run_results ~label ~stats ~wall_time =
  let open Online_learner in
  printf "%s results:\n%!" label;
  printf "  Games: %d, Final clusters: %d\n%!" stats.games_played stats.ev_graph_size;
  printf "  Cache hits: %d (%.1f%%), Misses: %d\n%!"
    stats.cache_hits
    (100.0 *. Float.of_int stats.cache_hits
     /. Float.of_int (Int.max 1 (stats.cache_hits + stats.cache_misses)))
    stats.cache_misses;
  printf "  Clusters created: %d, merged: %d\n%!"
    stats.clusters_created stats.clusters_merged;
  printf "  Compression: %.1fx\n%!"
    (Float.of_int stats.games_played
     /. Float.of_int (Int.max 1 stats.ev_graph_size));
  printf "  Wall time: %.2fs\n\n%!" wall_time

let () =
  printf "=== RBM Online Self-Play: Rhode Island Hold'em ===\n\n%!";

  (* Use a small deck (2 ranks = 8 cards) for fast iteration *)
  let n_ranks = 2 in
  let game_config = Rhode_island.small_config ~n_ranks in
  let deck = game_config.deck in
  printf "Deck (%d cards, %d ranks): %s\n%!"
    (List.length deck) n_ranks
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));

  (* Fixed community cards *)
  let flop = List.nth_exn deck 0 in
  let turn = List.nth_exn deck 1 in
  let community = [ flop; turn ] in
  printf "Community: %s %s\n%!"
    (Card.to_string flop) (Card.to_string turn);

  (* Count the number of distinct deals possible *)
  let remaining =
    List.filter deck ~f:(fun c ->
      not (Card.equal c flop) && not (Card.equal c turn))
  in
  let n_remaining = List.length remaining in
  let n_ordered_deals = n_remaining * (n_remaining - 1) in
  printf "Remaining cards: %d, Ordered deals: %d\n\n%!"
    n_remaining n_ordered_deals;

  let num_games = 1000 in

  let base_config = {
    Online_learner.game_config;
    epsilon = 200.0;
    community;
    num_games;
    report_interval = 100;
    merge_interval = 200;
    distance_config = Distance.default_config;
  } in

  (* ================================================================ *)
  (* Run 1: epsilon=50 (fine-grained)                                 *)
  (* ================================================================ *)
  printf "--- Run 1: epsilon=50.0, %d games ---\n\n%!" num_games;

  let config_50 = { base_config with epsilon = 50.0; merge_interval = 500 } in
  let ((stats_50, snaps_50), t_50) = time (fun () ->
    Online_learner.run_with_snapshots ~config:config_50)
  in
  print_run_results ~label:"Epsilon=50.0" ~stats:stats_50 ~wall_time:t_50;

  (* ================================================================ *)
  (* Run 2: epsilon=200 (moderate)                                    *)
  (* ================================================================ *)
  printf "--- Run 2: epsilon=200.0, %d games ---\n\n%!" num_games;

  let config_200 = base_config in
  let ((stats_200, snaps_200), t_200) = time (fun () ->
    Online_learner.run_with_snapshots ~config:config_200)
  in
  print_run_results ~label:"Epsilon=200.0" ~stats:stats_200 ~wall_time:t_200;

  (* ================================================================ *)
  (* Run 3: epsilon=500 (aggressive compression)                      *)
  (* ================================================================ *)
  printf "--- Run 3: epsilon=500.0, %d games ---\n\n%!" num_games;

  let config_500 = { base_config with epsilon = 500.0; merge_interval = 100 } in
  let ((stats_500, snaps_500), t_500) = time (fun () ->
    Online_learner.run_with_snapshots ~config:config_500)
  in
  print_run_results ~label:"Epsilon=500.0" ~stats:stats_500 ~wall_time:t_500;

  (* ================================================================ *)
  (* Convergence comparison table                                     *)
  (* ================================================================ *)
  printf "=== Convergence Comparison ===\n\n%!";
  printf "%8s  %18s  %18s  %18s\n%!"
    "game" "eps=50" "eps=200" "eps=500";
  printf "%8s  %18s  %18s  %18s\n%!"
    "" "clust (hit%%)" "clust (hit%%)" "clust (hit%%)";

  let max_snaps =
    Int.max (List.length snaps_50)
      (Int.max (List.length snaps_200) (List.length snaps_500))
  in
  for i = 0 to max_snaps - 1 do
    let get snaps =
      match List.nth snaps i with
      | Some s -> sprintf "%4d (%5.1f%%)" s.Online_learner.num_clusters
                    (100.0 *. s.cache_hit_rate)
      | None -> "        -       "
    in
    let game_num = (i + 1) * base_config.report_interval in
    printf "%8d  %18s  %18s  %18s\n%!"
      game_num (get snaps_50) (get snaps_200) (get snaps_500)
  done;

  printf "\n=== Summary ===\n%!";
  printf "The online self-play learner builds an EV graph incrementally through play.\n%!";
  printf "Key observations:\n%!";
  printf "  - Smaller epsilon -> more clusters, higher accuracy, lower compression\n%!";
  printf "  - Larger epsilon -> fewer clusters, faster convergence, more generalization\n%!";
  printf "  - Cache hit rate increases over time as the graph covers the deal space\n%!";
  printf "  - New cluster creation rate decreases (convergence indicator)\n%!";
  printf "  - With %d ordered deals, the graph converges when most deals\n%!"
    n_ordered_deals;
  printf "    match an existing cluster within epsilon\n%!";
  printf "  - Total wall time: %.1fs for %d total games across 3 epsilon values\n%!"
    (t_50 +. t_200 +. t_500) (3 * num_games);

  printf "\nDone.\n"
