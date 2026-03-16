open Rbm

(** Scale experiment: RBM vs EMD across 3-, 4-, 5-rank decks.
    Produces paper-quality tables comparing abstraction metrics
    at multiple compression levels, plus CFR exploitability on 3-rank. *)

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

(** Deterministic shuffle using a seed-based LCG. *)
let seeded_shuffle ~seed lst =
  let arr = Array.of_list lst in
  let n = Array.length arr in
  let state = ref seed in
  for i = n - 1 downto 1 do
    state := (!state * 1103515245 + 12345) land 0x7FFFFFFF;
    let j = !state mod (i + 1) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done;
  Array.to_list arr

(** Pairwise distance matrix using memoized distance.
    Significantly faster than [Ev_graph.precompute_distances] due to
    structural hash caching of identical subtrees across deals. *)
let precompute_distances_memoized (trees : 'a Tree.t list) =
  let n = List.length trees in
  let tree_arr = Array.of_list trees in
  let dist = Array.init n ~f:(fun i ->
    Array.init n ~f:(fun j ->
      match i <= j with
      | true -> Distance.compute_memoized tree_arr.(i) tree_arr.(j)
      | false -> 0.0))
  in
  for i = 0 to n - 1 do
    for j = 0 to i - 1 do
      dist.(i).(j) <- dist.(j).(i)
    done
  done;
  dist

(** Collect pairwise distances from upper triangle of a matrix. *)
let collect_pairwise_distances matrix n =
  let dists = ref [] in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      dists := matrix.(i).(j) :: !dists
    done
  done;
  List.sort !dists ~compare:Float.compare

(** Distance statistics for a sorted list of pairwise distances. *)
let distance_stats dists =
  let n = List.length dists in
  match n with
  | 0 -> (0.0, 0.0, 0.0, 0)
  | _ ->
    let min_d = List.hd_exn dists in
    let max_d = List.last_exn dists in
    let sum = List.fold dists ~init:0.0 ~f:( +. ) in
    let mean = sum /. Float.of_int n in
    let distinct =
      List.dedup_and_sort dists ~compare:(fun a b ->
        Float.compare
          (Float.round_decimal a ~decimal_digits:4)
          (Float.round_decimal b ~decimal_digits:4))
      |> List.length
    in
    (min_d, max_d, mean, distinct)

(** Cluster using only the precomputed distance matrix (no tree merging).
    Returns [(cluster_members, diameter)] list. *)
let cluster_by_distance_matrix ~epsilon (dist_matrix : float array array) n =
  let active = Array.create ~len:n true in
  let members = Array.init n ~f:(fun i -> [ i ]) in
  let diameters = Array.create ~len:n 0.0 in

  let continue = ref true in
  while !continue do
    let best_dist = ref Float.infinity in
    let best_ci = ref (-1) in
    let best_cj = ref (-1) in
    for ci = 0 to n - 1 do
      match active.(ci) with
      | false -> ()
      | true ->
        for cj = ci + 1 to n - 1 do
          match active.(cj) with
          | false -> ()
          | true ->
            let min_d = ref Float.infinity in
            List.iter members.(ci) ~f:(fun mi ->
              List.iter members.(cj) ~f:(fun mj ->
                let d = dist_matrix.(mi).(mj) in
                match Float.( < ) d !min_d with
                | true -> min_d := d
                | false -> ()));
            (match Float.( < ) !min_d !best_dist with
             | true -> best_dist := !min_d; best_ci := ci; best_cj := cj
             | false -> ())
        done
    done;

    match Float.( <= ) !best_dist epsilon && !best_ci >= 0 with
    | true ->
      let ci = !best_ci in
      let cj = !best_cj in
      members.(ci) <- members.(ci) @ members.(cj);
      diameters.(ci) <-
        Float.max (Float.max diameters.(ci) diameters.(cj)) !best_dist;
      active.(cj) <- false
    | false ->
      continue := false
  done;

  Array.to_list (Array.filter_mapi active ~f:(fun i is_active ->
    match is_active with
    | true -> Some (members.(i), diameters.(i))
    | false -> None))

(** Max EV error for a clustering using tree EVs. *)
let max_ev_error_tree trees_arr clusters =
  List.fold clusters ~init:0.0 ~f:(fun acc (member_indices, _diam) ->
    let evs = List.map member_indices ~f:(fun i ->
      Tree.ev trees_arr.(i)) in
    let mean_ev =
      let sum = List.fold evs ~init:0.0 ~f:( +. ) in
      sum /. Float.of_int (List.length evs)
    in
    let cluster_err = List.fold evs ~init:0.0 ~f:(fun acc ev ->
      Float.max acc (Float.abs (ev -. mean_ev)))
    in
    Float.max acc cluster_err)

(** Result record for one scale experiment. *)
type scale_result = {
  n_ranks : int;
  n_cards : int;
  n_deals : int;
  rbm_wins : int;
  emd_wins : int;
  ties : int;
  rbm_zero_err_k : int;    (** lowest k at which RBM achieves 0 error *)
  emd_zero_err_k : int;    (** lowest k at which EMD achieves 0 error *)
  rbm_time : float;
  emd_time : float;
  memo_stats : Distance.Memo.memo_stats;
}

(** Run abstraction comparison at one scale.
    Uses 2 rounds of betting with max 1 raise per round for richer
    game-tree structure, which makes RBM's structural sensitivity
    more meaningful relative to EMD's distribution-only view. *)
let run_scale ~n_ranks ~n_samples ~seed =
  let config = {
    Rhode_island.deck = Card.small_deck ~n_ranks;
    ante = 5;
    bet_sizes = [ 10; 10 ];
    max_raises = 1;
  } in
  let deck = config.deck in
  let n_cards = List.length deck in

  printf "\n============================================================\n";
  printf "  Scale: %d-rank deck (%d cards), %d sampled deals\n"
    n_ranks n_cards n_samples;
  printf "  Config: %d rounds, ante=%d, bet=%d, max_raises=%d\n"
    (List.length config.bet_sizes) config.ante
    (List.hd_exn config.bet_sizes) config.max_raises;
  printf "============================================================\n\n%!";

  let p1_card = List.hd_exn deck in
  printf "P1 hole card: %s\n%!" (Card.to_string p1_card);

  (* Enumerate all (opponent, flop, turn) deals *)
  let remaining_after_p1 =
    List.filter deck ~f:(fun c -> not (Card.equal c p1_card))
  in

  let all_deals =
    List.concat_map remaining_after_p1 ~f:(fun opp ->
      let after_opp =
        List.filter remaining_after_p1 ~f:(fun c -> not (Card.equal c opp))
      in
      List.concat_map after_opp ~f:(fun flop ->
        let after_flop =
          List.filter after_opp ~f:(fun c -> not (Card.equal c flop))
        in
        List.map after_flop ~f:(fun turn -> (opp, flop, turn))))
  in
  printf "Total enumerated deals: %d\n%!" (List.length all_deals);

  let sampled =
    seeded_shuffle ~seed all_deals
    |> (fun lst -> List.take lst n_samples)
  in
  let n = List.length sampled in
  printf "Sampled: %d deals\n\n%!" n;

  (* Generate trees and EMD distributions *)
  printf "Generating game trees and EMD distributions...\n%!";
  let (data, gen_time) = time (fun () ->
    List.map sampled ~f:(fun (opp, flop, turn) ->
      let community = [ flop; turn ] in
      let tree =
        Rhode_island.game_tree_for_deal ~config
          ~p1_card ~p2_card:opp ~community
      in
      let emd_dist =
        Emd_baseline.compute_distribution ~deck:config.deck
          ~p1_card ~community
      in
      (tree, emd_dist)))
  in
  printf "Generated %d trees in %.3fs\n%!" n gen_time;

  let trees = List.map data ~f:fst in
  let trees_arr = Array.of_list trees in
  let emd_dists_list = List.map data ~f:snd in

  (* Pairwise distance matrices *)
  printf "Computing RBM distance matrix (memoized)...\n%!";
  let (rbm_matrix, rbm_time) = time (fun () ->
    precompute_distances_memoized trees)
  in
  let memo_stats = Distance.Memo.stats () in
  printf "  RBM: %dx%d in %.3fs (memo: %d hits, %d misses)\n%!"
    n n rbm_time memo_stats.hits memo_stats.misses;

  let (emd_matrix, emd_time) = time (fun () ->
    Emd_baseline.pairwise_emd_matrix emd_dists_list)
  in
  printf "  EMD: %dx%d in %.3fs\n%!" n n emd_time;

  (* Distance statistics *)
  let rbm_pw = collect_pairwise_distances rbm_matrix n in
  let emd_pw = collect_pairwise_distances emd_matrix n in
  let _rbm_min, rbm_max, rbm_mean, rbm_distinct = distance_stats rbm_pw in
  let _emd_min, emd_max, emd_mean, emd_distinct = distance_stats emd_pw in

  printf "\nDistance statistics:\n%!";
  printf "  RBM: max=%.2f  mean=%.2f  distinct=%d\n%!"
    rbm_max rbm_mean rbm_distinct;
  printf "  EMD: max=%.4f  mean=%.4f  distinct=%d\n\n%!"
    emd_max emd_mean emd_distinct;

  (* Sweep compression levels *)
  let n_steps = 40 in

  let sweep_with_matrix dist_matrix max_dist =
    let results = ref [] in
    for step = 0 to n_steps do
      let frac = Float.of_int step /. Float.of_int n_steps in
      let eps = frac *. max_dist *. 1.1 in
      let clusters = cluster_by_distance_matrix ~epsilon:eps dist_matrix n in
      let k = List.length clusters in
      let err = max_ev_error_tree trees_arr clusters in
      results := (k, err) :: !results
    done;
    !results
  in

  let rbm_results = sweep_with_matrix rbm_matrix rbm_max in
  let emd_results = sweep_with_matrix emd_matrix emd_max in

  (* Deduplicate: keep best (lowest) error for each cluster count *)
  let best_at_k results =
    let h = Hashtbl.create (module Int) in
    List.iter results ~f:(fun (k, err) ->
      Hashtbl.update h k ~f:(function
        | None -> err
        | Some prev -> Float.min prev err));
    Hashtbl.to_alist h
    |> List.sort ~compare:(fun (k1, _) (k2, _) -> Int.compare k2 k1)
  in

  let rbm_by_k = best_at_k rbm_results in
  let emd_by_k = best_at_k emd_results in

  (* Target cluster counts *)
  let target_ks =
    [ n; 20; 15; 10; 7; 5; 3; 2; 1 ]
    |> List.filter ~f:(fun k -> k <= n)
    |> List.dedup_and_sort ~compare:Int.compare
    |> List.rev
  in

  let find_closest_k by_k target =
    List.fold by_k ~init:(None : (int * float) option)
      ~f:(fun best (k, err) ->
        match best with
        | None -> Some (k, err)
        | Some (bk, _) ->
          match Int.abs (k - target) < Int.abs (bk - target) with
          | true -> Some (k, err)
          | false -> best)
  in

  printf "  %-8s  %-9s  %-12s  %-12s  %-8s\n%!"
    "clusters" "compress" "RBM_err" "EMD_err" "Winner";
  printf "  %s\n%!" (String.make 57 '-');

  let rbm_wins_count = ref 0 in
  let emd_wins_count = ref 0 in
  let ties_count = ref 0 in

  (* Track lowest k with zero error *)
  let rbm_zero_k = ref n in
  let emd_zero_k = ref n in

  List.iter target_ks ~f:(fun target_k ->
    let rbm_entry = find_closest_k rbm_by_k target_k in
    let emd_entry = find_closest_k emd_by_k target_k in

    let comp = Float.of_int n /. Float.of_int (Int.max 1 target_k) in

    let format_entry entry =
      match entry with
      | None -> ("-", Float.infinity)
      | Some (k, err) ->
        match k = target_k with
        | true -> (sprintf "%.4f" err, err)
        | false -> (sprintf "%.4f[%d]" err k, err)
    in

    let rbm_str, rbm_err = format_entry rbm_entry in
    let emd_str, emd_err = format_entry emd_entry in

    (* Track zero-error k *)
    (match Float.( < ) (Float.abs rbm_err) 0.0001 with
     | true -> rbm_zero_k := Int.min !rbm_zero_k target_k
     | false -> ());
    (match Float.( < ) (Float.abs emd_err) 0.0001 with
     | true -> emd_zero_k := Int.min !emd_zero_k target_k
     | false -> ());

    (* Winner *)
    (match target_k = n with
     | true -> ()
     | false ->
       let tol = 0.0001 in
       let rbm_wins_here = Float.( < ) rbm_err (emd_err -. tol) in
       let emd_wins_here = Float.( < ) emd_err (rbm_err -. tol) in
       match rbm_wins_here with
       | true -> Int.incr rbm_wins_count
       | false ->
         match emd_wins_here with
         | true -> Int.incr emd_wins_count
         | false -> Int.incr ties_count);

    let winner =
      match target_k = n with
      | true -> "n/a"
      | false ->
        let tol = 0.0001 in
        match Float.( < ) (Float.abs (rbm_err -. emd_err)) tol with
        | true -> "tie"
        | false ->
          match Float.( < ) rbm_err emd_err with
          | true -> "RBM"
          | false -> "EMD"
    in
    printf "  %-8d  %-9s  %-12s  %-12s  %-8s\n%!"
      target_k (sprintf "%.1fx" comp) rbm_str emd_str winner);
  printf "\n%!";

  { n_ranks
  ; n_cards
  ; n_deals = n
  ; rbm_wins = !rbm_wins_count
  ; emd_wins = !emd_wins_count
  ; ties = !ties_count
  ; rbm_zero_err_k = !rbm_zero_k
  ; emd_zero_err_k = !emd_zero_k
  ; rbm_time
  ; emd_time
  ; memo_stats
  }

(** Run CFR comparison at 3-rank scale. *)
let run_cfr_comparison () =
  printf "\n============================================================\n";
  printf "  CFR Exploitability: RBM vs EMD compressed games (3-rank)\n";
  printf "============================================================\n\n%!";

  let config = {
    Rhode_island.deck = Card.small_deck ~n_ranks:3;
    ante = 5;
    bet_sizes = [ 10 ];
    max_raises = 1;
  } in
  let deck = config.deck in
  let flop = List.nth_exn deck 0 in
  let turn = List.nth_exn deck 5 in
  let community = [ flop; turn ] in

  let available = List.filter deck ~f:(fun c ->
    not (Card.equal c flop) && not (Card.equal c turn)) in
  let num_cards = List.length available in
  let cfr_iters = 1000 in

  printf "Deck: %s\n%!"
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));
  printf "Community: %s %s  |  Available: %d cards\n%!"
    (Card.to_string flop) (Card.to_string turn) num_cards;
  printf "CFR iterations: %d\n\n%!" cfr_iters;

  (* Full game baseline *)
  let ((full_p1, full_p2), full_time) = time (fun () ->
    Cfr.train ~config ~community ~iterations:cfr_iters) in
  let full_exploit = Cfr.exploitability ~config ~community full_p1 full_p2 in
  printf "Full game (%d clusters): exploit=%.6f (%.3fs)\n\n%!"
    num_cards full_exploit full_time;

  (* Build IS trees for compression *)
  let is_trees = List.map available ~f:(fun card ->
    Rhode_island.information_set_tree ~config ~player:0
      ~hole_card:card ~community) in

  (* RBM distance matrix (memoized) *)
  Distance.Memo.clear ();
  let (rbm_matrix, _) = time (fun () ->
    precompute_distances_memoized is_trees) in

  (* EMD distance matrix *)
  let emd_dists = List.map available ~f:(fun card ->
    Emd_baseline.compute_distribution ~deck:config.deck
      ~p1_card:card ~community) in
  let emd_matrix = Emd_baseline.pairwise_emd_matrix emd_dists in

  (* Max distances *)
  let rbm_max = ref 0.0 in
  let emd_max = ref 0.0 in
  for i = 0 to num_cards - 2 do
    for j = i + 1 to num_cards - 1 do
      (match Float.( > ) rbm_matrix.(i).(j) !rbm_max with
       | true -> rbm_max := rbm_matrix.(i).(j)
       | false -> ());
      (match Float.( > ) emd_matrix.(i).(j) !emd_max with
       | true -> emd_max := emd_matrix.(i).(j)
       | false -> ())
    done
  done;

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

  let target_clusters = [ 7; 5; 3; 2 ]
    |> List.filter ~f:(fun k -> k < num_cards && k > 1) in

  printf "  %-10s  %-6s  %-6s  %-12s  %-6s\n%!"
    "k_target" "method" "k_act" "exploit" "winner";
  printf "  %s\n%!" (String.make 50 '-');

  let cfr_rbm_wins = ref 0 in
  let cfr_emd_wins = ref 0 in
  let cfr_ties = ref 0 in

  List.iter target_clusters ~f:(fun target_k ->
    let rbm_opt = find_graph_at_k ~matrix:rbm_matrix ~max_dist:!rbm_max target_k in
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
        | true -> Int.incr cfr_ties; "tie"
        | false ->
          match Float.( < ) rbm_exploit emd_exploit with
          | true -> Int.incr cfr_rbm_wins; "RBM"
          | false -> Int.incr cfr_emd_wins; "EMD"
      in

      printf "  %-10d  %-6s  %-6d  %-12.6f\n%!" target_k "RBM" rbm_k rbm_exploit;
      printf "  %-10s  %-6s  %-6d  %-12.6f  %-6s\n%!" "" "EMD" emd_k emd_exploit winner_str
    | _ -> printf "  %-10d  (could not find matching epsilon)\n%!" target_k);

  printf "\n  CFR summary: RBM wins=%d, EMD wins=%d, ties=%d\n\n%!"
    !cfr_rbm_wins !cfr_emd_wins !cfr_ties;
  (!cfr_rbm_wins, !cfr_emd_wins, !cfr_ties)

let () =
  let t_start = Core_unix.gettimeofday () in

  printf "################################################################\n";
  printf "#  RBM vs EMD Scale Experiment for Paper                       #\n";
  printf "#  Recursive Bipartite Matching distance on game trees         #\n";
  printf "################################################################\n\n%!";

  let scales = [ (3, 30); (4, 30); (5, 30) ] in
  let seed = 42 in

  (* ================================================================ *)
  (* Part 1: Abstraction quality across scales                        *)
  (* ================================================================ *)
  printf "================================================================\n";
  printf "  PART 1: Abstraction Quality (RBM vs EMD) Across Scales\n";
  printf "================================================================\n%!";

  let scale_results = List.map scales ~f:(fun (n_ranks, n_samples) ->
    Distance.Memo.clear ();
    run_scale ~n_ranks ~n_samples ~seed)
  in

  (* ================================================================ *)
  (* Part 2: CFR exploitability (3-rank only)                         *)
  (* ================================================================ *)
  printf "\n================================================================\n";
  printf "  PART 2: CFR Exploitability (3-rank only)\n";
  printf "================================================================\n%!";

  let (cfr_rbm_wins, cfr_emd_wins, cfr_ties) = run_cfr_comparison () in

  (* ================================================================ *)
  (* Part 3: Summary tables for paper                                 *)
  (* ================================================================ *)
  let t_end = Core_unix.gettimeofday () in
  let total_time = t_end -. t_start in

  printf "\n================================================================\n";
  printf "  PART 3: Paper Summary Tables\n";
  printf "================================================================\n\n%!";

  (* Table 1: RBM vs EMD across game scales *)
  printf "Table 1: RBM vs EMD across game scales\n";
  printf "  (winner = lower max EV error at same compression level)\n\n";
  printf "  %-8s  %-6s  %-5s  %-9s  %-9s  %-5s  %-14s  %-14s\n%!"
    "Scale" "Cards" "Deals" "RBM_wins" "EMD_wins" "Ties"
    "RBM_zero_k" "EMD_zero_k";
  printf "  %s\n%!" (String.make 78 '-');

  List.iter scale_results ~f:(fun r ->
    printf "  %-8s  %-6d  %-5d  %-9d  %-9d  %-5d  %-14d  %-14d\n%!"
      (sprintf "%d-rank" r.n_ranks)
      r.n_cards r.n_deals
      r.rbm_wins r.emd_wins r.ties
      r.rbm_zero_err_k r.emd_zero_err_k);
  printf "\n%!";

  (* Table 2: Computational cost *)
  printf "Table 2: Computational cost (distance matrix time)\n\n";
  printf "  %-8s  %-6s  %-5s  %-10s  %-10s  %-10s  %-10s\n%!"
    "Scale" "Cards" "Deals" "RBM_time" "EMD_time"
    "Memo_hits" "Memo_miss";
  printf "  %s\n%!" (String.make 68 '-');

  List.iter scale_results ~f:(fun r ->
    printf "  %-8s  %-6d  %-5d  %-10.3f  %-10.3f  %-10d  %-10d\n%!"
      (sprintf "%d-rank" r.n_ranks)
      r.n_cards r.n_deals
      r.rbm_time r.emd_time
      r.memo_stats.hits r.memo_stats.misses);
  printf "\n%!";

  (* Table 3: CFR exploitability *)
  printf "Table 3: CFR exploitability comparison (3-rank, 1000 iterations)\n\n";
  printf "  RBM wins: %d  |  EMD wins: %d  |  Ties: %d\n\n%!"
    cfr_rbm_wins cfr_emd_wins cfr_ties;
  printf "  Lower exploitability = better abstraction for equilibrium finding.\n";
  printf "  RBM captures game-tree strategic structure; EMD sees only showdown\n";
  printf "  outcome distributions.\n\n%!";

  (* Aggregate summary *)
  let total_rbm = List.sum (module Int) scale_results ~f:(fun r -> r.rbm_wins) in
  let total_emd = List.sum (module Int) scale_results ~f:(fun r -> r.emd_wins) in
  let total_ties = List.sum (module Int) scale_results ~f:(fun r -> r.ties) in

  printf "Aggregate: RBM wins %d, EMD wins %d, Ties %d across all scales\n%!"
    total_rbm total_emd total_ties;
  printf "Total runtime: %.1fs\n\n%!" total_time;
  printf "Done.\n"
