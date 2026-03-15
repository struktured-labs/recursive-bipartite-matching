open Rbm

(** RBM vs EMD comparison with varied community cards.

    Instead of fixing community cards (which creates degenerate 3-cluster
    structure), we vary (opponent, flop, turn) to create genuine strategic
    diversity: flush draws, straight draws, high-card vs pair boards, etc.

    For each sampled deal we build a concrete game tree via
    [game_tree_for_deal] (~1141 nodes), which is fast enough for pairwise
    RBM distance.  For the EMD baseline, we compute the showdown outcome
    distribution for that (p1, community) pair over all possible opponents,
    giving the standard poker-AI hand-strength abstraction. *)

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

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

(** A sampled deal: p1 fixed, opponent + community vary. *)
type sampled_deal = {
  opp_card : Card.t;
  flop : Card.t;
  turn : Card.t;
  tree : Rhode_island.Node_label.t Tree.t;
  emd_dist : Emd_baseline.hand_distribution;
}

(** Cluster using only the precomputed distance matrix (no tree merging).
    This is much faster than Ev_graph.compress because it skips the expensive
    Merge.merge_weighted step.  Returns (cluster_assignments, num_clusters)
    where each element is a list of member indices. *)
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
            match Float.( < ) !min_d !best_dist with
            | true -> best_dist := !min_d; best_ci := ci; best_cj := cj
            | false -> ()
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

  let clusters =
    Array.to_list (Array.filter_mapi active ~f:(fun i is_active ->
      match is_active with
      | true -> Some (members.(i), diameters.(i))
      | false -> None))
  in
  clusters

(** Compute max EV error for any clustering using TREE EVs.
    All methods are compared on the same ground-truth metric:
    tree EV captures the full game-theoretic value including
    folding, betting, and showdown outcomes. *)
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

let () =
  let n_ranks = 3 in
  let n_samples = 25 in
  let seed = 42 in

  printf "=== RBM vs EMD Comparison (varied community cards) ===\n";
  printf "Deck: %d-rank (%d cards), P1 holds: 2c\n" n_ranks (n_ranks * 4);
  printf "Target samples: %d\n\n%!" n_samples;

  let config = Rhode_island.small_config ~n_ranks in
  let deck = config.deck in
  printf "Deck: %s\n%!"
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));

  (* Fix P1's hole card to 2c (first card in deck) *)
  let p1_card = List.hd_exn deck in
  printf "P1 hole card: %s\n\n%!" (Card.to_string p1_card);

  (* Enumerate all (opponent, flop, turn) deals.
     Remaining deck after removing p1: 11 cards.
     Deals: 11 x 10 x 9 = 990 ordered triples *)
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

  (* Sample deterministically *)
  let sampled =
    seeded_shuffle ~seed all_deals
    |> (fun lst -> List.take lst n_samples)
  in
  let n = List.length sampled in
  printf "Sampled: %d deals\n\n%!" n;

  (* ================================================================ *)
  (* [1] Generate game trees and distributions                        *)
  (* ================================================================ *)
  printf "--- [1] Generating game trees and EMD distributions ---\n\n%!";

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
      { opp_card = opp; flop; turn; tree; emd_dist }))
  in
  printf "Generated %d deal trees + distributions in %.3fs\n%!" n gen_time;

  let sample_tree = (List.hd_exn data).tree in
  printf "Each deal tree: %d nodes, %d leaves, depth %d\n\n%!"
    (Tree.size sample_tree) (Tree.num_leaves sample_tree) (Tree.depth sample_tree);

  (* Show sample of deals *)
  printf "Sample deals (first 15):\n%!";
  printf "  %-6s  %-12s  %6s  %6s  %6s  %7s\n%!"
    "Opp" "Community" "Win%" "Draw%" "Lose%" "EV";
  List.iteri data ~f:(fun i d ->
    match i < 15 with
    | true ->
      printf "  %-6s  %-12s  %5.1f%%  %5.1f%%  %5.1f%%  %+.3f\n%!"
        (Card.to_string d.opp_card)
        (Card.to_string d.flop ^ " " ^ Card.to_string d.turn)
        (d.emd_dist.win_prob *. 100.0)
        (d.emd_dist.draw_prob *. 100.0)
        (d.emd_dist.lose_prob *. 100.0)
        d.emd_dist.ev
    | false -> ());
  (match n > 15 with
   | true -> printf "  ... (%d more)\n%!" (n - 15)
   | false -> ());
  printf "\n%!";

  (* ================================================================ *)
  (* [2] Pairwise distance matrices                                   *)
  (* ================================================================ *)
  printf "--- [2] Pairwise distance matrices ---\n\n%!";

  let trees = List.map data ~f:(fun d -> d.tree) in
  let trees_arr = Array.of_list trees in
  let emd_dists_list = List.map data ~f:(fun d -> d.emd_dist) in

  let (rbm_matrix, rbm_time) = time (fun () ->
    Ev_graph.precompute_distances trees)
  in
  printf "RBM distance matrix: %dx%d computed in %.3fs (%d pairs)\n%!"
    n n rbm_time (n * (n - 1) / 2);

  let (emd_matrix, emd_time) = time (fun () ->
    Emd_baseline.pairwise_emd_matrix emd_dists_list)
  in
  printf "EMD distance matrix: %dx%d computed in %.3fs\n%!" n n emd_time;

  let (ev_matrix, ev_time) = time (fun () ->
    Emd_baseline.pairwise_ev_matrix emd_dists_list)
  in
  printf "EV distance matrix:  %dx%d computed in %.3fs\n\n%!" n n ev_time;

  (* Distance statistics *)
  let rbm_pw = collect_pairwise_distances rbm_matrix n in
  let emd_pw = collect_pairwise_distances emd_matrix n in
  let ev_pw = collect_pairwise_distances ev_matrix n in

  let rbm_min, rbm_max, rbm_mean, rbm_distinct = distance_stats rbm_pw in
  let emd_min, emd_max, emd_mean, emd_distinct = distance_stats emd_pw in
  let ev_min, ev_max, ev_mean, ev_distinct = distance_stats ev_pw in

  printf "Distance statistics:\n%!";
  printf "  RBM: min=%.2f  max=%.2f  mean=%.2f  distinct=%d\n%!"
    rbm_min rbm_max rbm_mean rbm_distinct;
  printf "  EMD: min=%.4f  max=%.4f  mean=%.4f  distinct=%d\n%!"
    emd_min emd_max emd_mean emd_distinct;
  printf "  EV:  min=%.4f  max=%.4f  mean=%.4f  distinct=%d\n\n%!"
    ev_min ev_max ev_mean ev_distinct;

  (* ================================================================ *)
  (* [3] Compression vs Error table                                   *)
  (* ================================================================ *)
  printf "--- [3] Compression vs Error ---\n\n%!";

  (* Use the fast distance-matrix-only clustering (no tree merging).
     This allows dense sweeps without the O(n^2 * tree_size) merge cost. *)
  let n_steps = 40 in

  let sweep_with_matrix dist_matrix max_dist ev_fn =
    let results = ref [] in
    for step = 0 to n_steps do
      let frac = Float.of_int step /. Float.of_int n_steps in
      let eps = frac *. max_dist *. 1.1 in
      let clusters = cluster_by_distance_matrix ~epsilon:eps dist_matrix n in
      let k = List.length clusters in
      let err = ev_fn clusters in
      results := (k, err) :: !results
    done;
    !results
  in

  let (rbm_results, rbm_sweep_t) = time (fun () ->
    sweep_with_matrix rbm_matrix rbm_max (max_ev_error_tree trees_arr))
  in
  let (emd_results, emd_sweep_t) = time (fun () ->
    sweep_with_matrix emd_matrix emd_max (max_ev_error_tree trees_arr))
  in
  let (ev_results, ev_sweep_t) = time (fun () ->
    sweep_with_matrix ev_matrix ev_max (max_ev_error_tree trees_arr))
  in
  printf "Sweep times: RBM=%.3fs  EMD=%.3fs  EV=%.3fs\n\n%!"
    rbm_sweep_t emd_sweep_t ev_sweep_t;

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
  let ev_by_k = best_at_k ev_results in

  (* Target cluster counts *)
  let target_ks =
    [ n; 20; 15; 10; 7; 5; 3; 2; 1 ]
    |> List.filter ~f:(fun k -> k <= n)
    |> List.dedup_and_sort ~compare:Int.compare
    |> List.rev
  in

  (* For a target k, find the entry with the closest cluster count *)
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

  printf "  %-8s  %-9s  %-12s  %-12s  %-12s  %-8s\n%!"
    "clusters" "compress" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 73 '-');

  List.iter target_ks ~f:(fun target_k ->
    let rbm_entry = find_closest_k rbm_by_k target_k in
    let emd_entry = find_closest_k emd_by_k target_k in
    let ev_entry = find_closest_k ev_by_k target_k in

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
    let ev_str, ev_err = format_entry ev_entry in

    let winner =
      let candidates = [
        ("RBM", rbm_err);
        ("EMD", emd_err);
        ("EV", ev_err);
      ] |> List.filter ~f:(fun (_, e) -> Float.is_finite e)
      in
      match candidates with
      | [] -> "N/A"
      | _ ->
        let all_zero = List.for_all candidates ~f:(fun (_, e) ->
          Float.( < ) (Float.abs e) 0.0001) in
        match all_zero with
        | true -> "tie"
        | false ->
          let best_name, _ =
            List.fold candidates ~init:("", Float.infinity)
              ~f:(fun (bn, be) (name, err) ->
                match Float.( < ) err be with
                | true -> (name, err)
                | false -> (bn, be))
          in
          best_name
    in
    printf "  %-8d  %-9s  %-12s  %-12s  %-12s  %-8s\n%!"
      target_k (sprintf "%.1fx" comp) rbm_str emd_str ev_str winner);
  printf "\n%!";

  (* ================================================================ *)
  (* [4] Detailed cluster analysis at moderate compression            *)
  (* ================================================================ *)
  printf "--- [4] Detailed cluster analysis ---\n\n%!";

  (* Find the epsilon that produces closest to 5 clusters from sweep data *)
  let find_eps_for_k ~target_k dist_matrix max_dist =
    let best_eps = ref 0.0 in
    let best_k = ref n in
    for step = 0 to 100 do
      let frac = Float.of_int step /. 100.0 in
      let eps = frac *. max_dist *. 1.1 in
      let clusters = cluster_by_distance_matrix ~epsilon:eps dist_matrix n in
      let k = List.length clusters in
      match Int.abs (k - target_k) < Int.abs (!best_k - target_k) with
      | true -> best_eps := eps; best_k := k
      | false -> ()
    done;
    (!best_eps, !best_k)
  in

  let (rbm_eps_5, _) = find_eps_for_k ~target_k:5 rbm_matrix rbm_max in
  let rbm_clusters_5 = cluster_by_distance_matrix ~epsilon:rbm_eps_5 rbm_matrix n in
  let rbm_k_5 = List.length rbm_clusters_5 in
  let rbm_ev_err_5 = max_ev_error_tree trees_arr rbm_clusters_5 in
  printf "RBM clusters (k=%d, eps=%.2f, ev_err=%.4f):\n%!" rbm_k_5 rbm_eps_5 rbm_ev_err_5;
  List.iteri rbm_clusters_5 ~f:(fun ci (member_indices, diam) ->
    let member_strs = List.map member_indices ~f:(fun idx ->
      let d = List.nth_exn data idx in
      sprintf "%s|%s+%s"
        (Card.to_string d.opp_card)
        (Card.to_string d.flop)
        (Card.to_string d.turn))
    in
    let n_members = List.length member_indices in
    let evs = List.map member_indices ~f:(fun i -> Tree.ev trees_arr.(i)) in
    let min_ev = List.fold evs ~init:Float.infinity ~f:Float.min in
    let max_ev = List.fold evs ~init:Float.neg_infinity ~f:Float.max in
    printf "  C%d (%d members, diam=%.1f, EV=[%+.2f..%+.2f]):\n%!"
      ci n_members diam min_ev max_ev;
    printf "    %s\n%!" (String.concat ~sep:", " member_strs));
  printf "\n%!";

  let (emd_eps_5, _) = find_eps_for_k ~target_k:5 emd_matrix emd_max in
  let emd_clusters_5 = cluster_by_distance_matrix ~epsilon:emd_eps_5 emd_matrix n in
  let emd_k_5 = List.length emd_clusters_5 in
  let emd_ev_err_5 = max_ev_error_tree trees_arr emd_clusters_5 in
  printf "EMD clusters (k=%d, eps=%.4f, ev_err=%.4f):\n%!" emd_k_5 emd_eps_5 emd_ev_err_5;
  List.iteri emd_clusters_5 ~f:(fun ci (member_indices, diam) ->
    let member_strs = List.map member_indices ~f:(fun idx ->
      let d = List.nth_exn data idx in
      sprintf "%s|%s+%s"
        (Card.to_string d.opp_card)
        (Card.to_string d.flop)
        (Card.to_string d.turn))
    in
    let n_members = List.length member_indices in
    let evs = List.map member_indices ~f:(fun i -> Tree.ev trees_arr.(i)) in
    let min_ev = List.fold evs ~init:Float.infinity ~f:Float.min in
    let max_ev = List.fold evs ~init:Float.neg_infinity ~f:Float.max in
    printf "  C%d (%d members, diam=%.4f, EV=[%+.3f..%+.3f]):\n%!"
      ci n_members diam min_ev max_ev;
    printf "    %s\n%!" (String.concat ~sep:", " member_strs));
  printf "\n%!";

  (* ================================================================ *)
  (* [5] Summary                                                      *)
  (* ================================================================ *)
  printf "--- [5] Summary ---\n\n%!";

  let rbm_wins = ref 0 in
  let emd_wins = ref 0 in
  let ev_wins = ref 0 in
  let ties = ref 0 in

  List.iter target_ks ~f:(fun target_k ->
    match target_k = n with
    | true -> ()
    | false ->
      let get_err by_k =
        Option.map (find_closest_k by_k target_k)
          ~f:snd |> Option.value ~default:Float.infinity
      in
      let rbm_err = get_err rbm_by_k in
      let emd_err = get_err emd_by_k in
      let ev_err = get_err ev_by_k in
      let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
      let tol = 0.0001 in
      let rbm_wins_here = Float.( < ) (Float.abs (rbm_err -. min_err)) tol in
      let emd_wins_here = Float.( < ) (Float.abs (emd_err -. min_err)) tol in
      let ev_wins_here = Float.( < ) (Float.abs (ev_err -. min_err)) tol in
      match rbm_wins_here && emd_wins_here && ev_wins_here with
      | true -> Int.incr ties
      | false ->
        match rbm_wins_here with
        | true -> Int.incr rbm_wins
        | false ->
          match emd_wins_here with
          | true -> Int.incr emd_wins
          | false ->
            match ev_wins_here with
            | true -> Int.incr ev_wins
            | false -> Int.incr ties);

  let n_compared = List.length target_ks - 1 in
  printf "Wins across %d compression levels (excluding trivial k=%d):\n%!"
    n_compared n;
  printf "  RBM: %d wins\n%!" !rbm_wins;
  printf "  EMD: %d wins\n%!" !emd_wins;
  printf "  EV:  %d wins\n%!" !ev_wins;
  printf "  Tie: %d\n\n%!" !ties;

  printf "Key insight: With varied community cards, each (flop, turn) creates\n\
         genuinely different strategic situations (pairs on board, flush\n\
         possibilities, different relative hand strengths). RBM captures\n\
         the STRUCTURAL differences in the game tree (how the betting\n\
         strategies differ), while EMD only sees the showdown outcome\n\
         distribution. Two boards with similar win rates can have very\n\
         different optimal play when the game tree structure differs.\n\n%!";

  printf "Done.\n"
