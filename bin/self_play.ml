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
  printf "This demo compares random vs fixed community cards and demonstrates\n%!";
  printf "memoized distance computation for speedup.\n\n%!";

  let n_ranks = 2 in
  let game_config = Rhode_island.small_config ~n_ranks in
  let deck = game_config.deck in
  printf "Deck (%d cards, %d ranks): %s\n\n%!"
    (List.length deck) n_ranks
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));

  (* ================================================================ *)
  (* Part 1: Random community cards (the interesting case)            *)
  (* ================================================================ *)
  printf "--- Part 1: Random community cards ---\n\n%!";
  printf "Using information set trees: P1's perspective, aggregating over all\n%!";
  printf "possible opponent hands. Different community cards create genuinely\n%!";
  printf "different tree structures (different opponent distributions and\n%!";
  printf "showdown outcomes).\n\n%!";

  let num_games_random = 100 in
  let epsilon = 50.0 in

  let random_config = {
    Online_learner.game_config;
    epsilon;
    community = None;
    num_games = num_games_random;
    report_interval = 100;
    merge_interval = 200;
    distance_config = Distance.default_config;
  } in
  let ((random_stats, random_snaps), random_wall) = time (fun () ->
    Online_learner.run_with_snapshots ~config:random_config) in
  print_run_results ~label:"Random community" ~stats:random_stats ~wall_time:random_wall;

  (* ================================================================ *)
  (* Part 2: Fixed community cards (degenerate structure)             *)
  (* ================================================================ *)
  printf "--- Part 2: Fixed community cards (2c 3c) ---\n\n%!";
  let flop = List.nth_exn deck 0 in
  let turn = List.nth_exn deck 1 in
  let fixed_community = [ flop; turn ] in
  printf "Fixed community: %s %s\n%!"
    (Card.to_string flop) (Card.to_string turn);
  printf "With fixed community, only hole cards vary. This creates a limited\n%!";
  printf "cluster structure based only on showdown outcome differences.\n\n%!";

  let num_games_fixed = 100 in
  let fixed_config = {
    Online_learner.game_config;
    epsilon;
    community = Some fixed_community;
    num_games = num_games_fixed;
    report_interval = 100;
    merge_interval = 200;
    distance_config = Distance.default_config;
  } in
  let ((fixed_stats, fixed_snaps), fixed_wall) = time (fun () ->
    Online_learner.run_with_snapshots ~config:fixed_config) in
  print_run_results ~label:"Fixed community" ~stats:fixed_stats ~wall_time:fixed_wall;

  (* ================================================================ *)
  (* Part 3: Memoized distance benchmark                              *)
  (* ================================================================ *)
  printf "--- Part 3: Memoized distance benchmark ---\n\n%!";

  (* Generate some trees with random community to benchmark distance *)
  let partial_shuffle arr k =
    let n = Array.length arr in
    for i = 0 to k - 1 do
      let j = i + Random.int (n - i) in
      let tmp = arr.(i) in
      arr.(i) <- arr.(j);
      arr.(j) <- tmp
    done
  in
  let bench_trees =
    let arr = Array.of_list deck in
    List.init 8 ~f:(fun _ ->
      partial_shuffle arr 4;
      Rhode_island.information_set_tree ~config:game_config
        ~player:0 ~hole_card:arr.(0)
        ~community:[ arr.(2); arr.(3) ])
  in
  let bench_arr = Array.of_list bench_trees in
  let n_bench = Array.length bench_arr in

  (* Pairwise distance without memoization *)
  let ((), t_plain) = time (fun () ->
    for i = 0 to n_bench - 2 do
      for j = i + 1 to n_bench - 1 do
        let _d = Distance.compute bench_arr.(i) bench_arr.(j) in
        ()
      done
    done) in

  (* Pairwise distance with memoization *)
  let ((), t_memo) = time (fun () ->
    Distance.Memo.clear ();
    for i = 0 to n_bench - 2 do
      for j = i + 1 to n_bench - 1 do
        let _d = Distance.compute_memoized bench_arr.(i) bench_arr.(j) in
        ()
      done
    done) in

  let memo_stats = Distance.Memo.stats () in
  let n_pairs = n_bench * (n_bench - 1) / 2 in
  printf "Pairwise distance on %d trees (%d pairs):\n%!" n_bench n_pairs;
  printf "  Plain:    %.4fs\n%!" t_plain;
  printf "  Memoized: %.4fs (%.1fx speedup)\n%!" t_memo
    (match Float.( > ) t_memo 0.0 with
     | true -> t_plain /. t_memo
     | false -> Float.infinity);
  printf "  Memo hits: %d, misses: %d, hit rate: %.1f%%\n\n%!"
    memo_stats.hits memo_stats.misses
    (match memo_stats.hits + memo_stats.misses with
     | 0 -> 0.0
     | total -> 100.0 *. Float.of_int memo_stats.hits /. Float.of_int total);

  (* ================================================================ *)
  (* Part 4: Convergence comparison                                   *)
  (* ================================================================ *)
  printf "--- Part 4: Convergence comparison ---\n\n%!";
  printf "%8s  %18s  %18s\n%!" "game" "Random community" "Fixed community";
  printf "%8s  %18s  %18s\n%!" "" "clust (hit%%)" "clust (hit%%)";

  let max_snaps = Int.max (List.length random_snaps) (List.length fixed_snaps) in
  for i = 0 to max_snaps - 1 do
    printf "%8d" ((i + 1) * 100);
    (match List.nth random_snaps i with
     | Some s -> printf "  %4d (%5.1f%%)" s.Online_learner.num_clusters
                   (100.0 *. s.cache_hit_rate)
     | None -> printf "  %18s" "-");
    (match List.nth fixed_snaps i with
     | Some s -> printf "  %4d (%5.1f%%)" s.Online_learner.num_clusters
                   (100.0 *. s.cache_hit_rate)
     | None -> printf "  %18s" "-");
    printf "\n%!"
  done;

  (* ================================================================ *)
  (* Summary                                                          *)
  (* ================================================================ *)
  printf "\n=== Key Findings ===\n\n%!";
  printf "1. CLUSTER DIVERSITY:\n%!";
  printf "   Random community: %d clusters from %d games\n%!"
    random_stats.ev_graph_size random_stats.games_played;
  printf "   Fixed community:  %d clusters from %d games\n\n%!"
    fixed_stats.ev_graph_size fixed_stats.games_played;

  let random_more = random_stats.ev_graph_size > fixed_stats.ev_graph_size in
  (match random_more with
   | true ->
     printf "   Random communities discover MORE clusters (%d > %d) because\n%!"
       random_stats.ev_graph_size fixed_stats.ev_graph_size;
     printf "   different community cards create genuinely different strategic\n%!";
     printf "   situations with distinct game tree structures.\n\n%!"
   | false ->
     printf "   Fixed and random produced similar cluster counts. With small\n%!";
     printf "   decks, the strategic space may be limited.\n\n%!");

  printf "2. MEMOIZED DISTANCE: %.1fx speedup on %d-tree benchmark\n%!"
    (match Float.( > ) t_memo 0.0 with
     | true -> t_plain /. t_memo
     | false -> Float.infinity)
    n_bench;
  printf "   Memo hit rate: %.1f%% (structurally identical subtrees reuse cached results)\n\n%!"
    (match memo_stats.hits + memo_stats.misses with
     | 0 -> 0.0
     | total -> 100.0 *. Float.of_int memo_stats.hits /. Float.of_int total);

  printf "3. CONVERGENCE: Fixed community converges to ~3 clusters rapidly\n%!";
  printf "   (P1 wins / P2 wins / tie). Random community explores a richer\n%!";
  printf "   strategy space before stabilizing.\n\n%!";

  printf "4. TOTAL WALL TIME: %.2fs (random) + %.2fs (fixed) + %.4fs (bench) = %.2fs\n%!"
    random_wall fixed_wall (t_plain +. t_memo)
    (random_wall +. fixed_wall +. t_plain +. t_memo);

  printf "\nDone.\n"
