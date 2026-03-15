open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

let () =
  printf "=== RBM Online Self-Play: Rhode Island Hold'em ===\n\n%!";

  (* Use a small deck (2-3 ranks) for fast iteration *)
  let n_ranks = 3 in
  let game_config = Rhode_island.small_config ~n_ranks in
  let deck = game_config.deck in
  printf "Deck (%d cards, %d ranks): %s\n%!"
    (List.length deck) n_ranks
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));

  (* Fixed community cards *)
  let flop = List.nth_exn deck 0 in  (* 2c *)
  let turn = List.nth_exn deck 1 in  (* 3c *)
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

  (* ================================================================ *)
  (* Run 1: Baseline with epsilon=200 (moderate clustering)           *)
  (* ================================================================ *)
  printf "--- Run 1: epsilon=200.0, 1000 games ---\n\n%!";

  let config_200 = {
    Online_learner.game_config;
    epsilon = 200.0;
    community;
    num_games = 1000;
    report_interval = 100;
    merge_interval = 200;
    distance_config = Distance.default_config;
  } in

  let ((), t_run1) = time (fun () ->
    Online_learner.run_with_report ~config:config_200)
  in
  printf "\nRun 1 wall time: %.2fs\n\n%!" t_run1;

  (* ================================================================ *)
  (* Run 2: Tight epsilon=50 (fine-grained clustering)                *)
  (* ================================================================ *)
  printf "--- Run 2: epsilon=50.0, 1000 games ---\n\n%!";

  let config_50 = { config_200 with
    epsilon = 50.0;
    merge_interval = 500;  (* merge less often since epsilon is tight *)
  } in

  let ((stats_50, snaps_50), t_run2) = time (fun () ->
    Online_learner.run_with_snapshots ~config:config_50)
  in
  printf "Epsilon=50.0 results:\n%!";
  printf "  Games: %d, Clusters: %d, Hits: %d, Misses: %d\n%!"
    stats_50.games_played stats_50.ev_graph_size
    stats_50.cache_hits stats_50.cache_misses;
  printf "  Hit rate: %.1f%%\n%!"
    (100.0 *. Float.of_int stats_50.cache_hits
     /. Float.of_int (Int.max 1 (stats_50.cache_hits + stats_50.cache_misses)));
  printf "  Compression: %.1fx\n%!"
    (Float.of_int stats_50.games_played
     /. Float.of_int (Int.max 1 stats_50.ev_graph_size));
  printf "  Wall time: %.2fs\n\n%!" t_run2;

  (* ================================================================ *)
  (* Run 3: Large epsilon=500 (aggressive compression)                *)
  (* ================================================================ *)
  printf "--- Run 3: epsilon=500.0, 1000 games ---\n\n%!";

  let config_500 = { config_200 with
    epsilon = 500.0;
    merge_interval = 100;
  } in

  let ((stats_500, snaps_500), t_run3) = time (fun () ->
    Online_learner.run_with_snapshots ~config:config_500)
  in
  printf "Epsilon=500.0 results:\n%!";
  printf "  Games: %d, Clusters: %d, Hits: %d, Misses: %d\n%!"
    stats_500.games_played stats_500.ev_graph_size
    stats_500.cache_hits stats_500.cache_misses;
  printf "  Hit rate: %.1f%%\n%!"
    (100.0 *. Float.of_int stats_500.cache_hits
     /. Float.of_int (Int.max 1 (stats_500.cache_hits + stats_500.cache_misses)));
  printf "  Compression: %.1fx\n%!"
    (Float.of_int stats_500.games_played
     /. Float.of_int (Int.max 1 stats_500.ev_graph_size));
  printf "  Wall time: %.2fs\n\n%!" t_run3;

  (* ================================================================ *)
  (* Convergence comparison                                           *)
  (* ================================================================ *)
  printf "=== Convergence Comparison ===\n\n%!";
  printf "%8s  %14s  %14s  %14s\n%!"
    "game" "eps=50 clust" "eps=200 clust" "eps=500 clust";

  (* Re-run epsilon=200 with snapshots for the comparison *)
  let (_stats_200, snaps_200) =
    Online_learner.run_with_snapshots ~config:config_200
  in

  (* Zip all three snapshot lists together *)
  let max_snaps =
    Int.max (List.length snaps_50)
      (Int.max (List.length snaps_200) (List.length snaps_500))
  in
  for i = 0 to max_snaps - 1 do
    let get snaps =
      match List.nth snaps i with
      | Some s -> sprintf "%4d (%.0f%%)" s.Online_learner.num_clusters
                    (100.0 *. s.cache_hit_rate)
      | None -> "          -"
    in
    let game_num =
      match List.nth snaps_50 i with
      | Some s -> s.Online_learner.game_number
      | None ->
        (match List.nth snaps_200 i with
         | Some s -> s.Online_learner.game_number
         | None ->
           (match List.nth snaps_500 i with
            | Some s -> s.Online_learner.game_number
            | None -> (i + 1) * 100))
    in
    printf "%8d  %14s  %14s  %14s\n%!"
      game_num (get snaps_50) (get snaps_200) (get snaps_500)
  done;

  printf "\n=== Summary ===\n%!";
  printf "The online self-play learner builds an EV graph incrementally.\n%!";
  printf "Key observations:\n%!";
  printf "  - Smaller epsilon -> more clusters, higher accuracy, lower compression\n%!";
  printf "  - Larger epsilon -> fewer clusters, faster convergence, more generalization\n%!";
  printf "  - Cache hit rate increases over time as the graph covers more of the deal space\n%!";
  printf "  - New cluster creation rate decreases over time (convergence)\n%!";
  printf "  - With %d ordered deals possible, the graph converges when most deals\n%!"
    n_ordered_deals;
  printf "    match an existing cluster within epsilon\n%!";

  printf "\nDone.\n"
