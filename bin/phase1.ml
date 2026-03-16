open Rbm

(** Phase 1: Full 52-card Rhode Island Hold'em RBM experiment.

    Fix P1's hole card to Ace of spades and sample 100 different
    community card pairs (flop, turn).  For each community, build an
    information set tree: P1 knows their card and the community but NOT
    the opponent's card.  The IS tree has ~49 opponent branches, each
    containing a full game tree.

    Different communities produce genuinely different IS trees because
    the hand rankings against all 49 possible opponents differ --
    pairs, flushes, straights, high cards create structurally distinct
    subtree distributions.

    Uses NON-memoized RBM distance for accuracy: memoized distance
    hashes tree structure and collapses trees with identical shape but
    different leaf values. *)

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
  | 0 -> (0.0, 0.0, 0.0, 0.0, 0)
  | _ ->
    let min_d = List.hd_exn dists in
    let max_d = List.last_exn dists in
    let sum = List.fold dists ~init:0.0 ~f:( +. ) in
    let mean = sum /. Float.of_int n in
    let variance =
      List.fold dists ~init:0.0 ~f:(fun acc d ->
        acc +. (d -. mean) *. (d -. mean))
      /. Float.of_int n
    in
    let stddev = Float.sqrt variance in
    let distinct =
      List.dedup_and_sort dists ~compare:(fun a b ->
        Float.compare
          (Float.round_decimal a ~decimal_digits:6)
          (Float.round_decimal b ~decimal_digits:6))
      |> List.length
    in
    (min_d, max_d, mean, stddev, distinct)

(** Cluster using only the precomputed distance matrix (no tree merging). *)
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

(** A sampled community with its IS tree and EMD distribution. *)
type sampled_community = {
  flop : Card.t;
  turn : Card.t;
  is_tree : Rhode_island.Node_label.t Tree.t;
  emd_dist : Emd_baseline.hand_distribution;
}

(** Format a community as a compact string. *)
let community_string d =
  sprintf "%s+%s"
    (Card.to_string d.flop)
    (Card.to_string d.turn)

(** Describe the hand category for a 3-card hand. *)
let hand_category p1_card flop turn =
  let rank, _kickers = Hand_eval.evaluate p1_card flop turn in
  match rank with
  | Hand_eval.Hand_rank.Three_of_a_kind -> "trips"
  | Pair -> "pair"
  | Flush -> "flush"
  | Straight -> "straight"
  | High_card -> "high"

let () =
  let t_start = Core_unix.gettimeofday () in
  let n_samples = 100 in
  let seed = 42 in

  printf "################################################################\n";
  printf "#  Phase 1: Full 52-Card Rhode Island Hold'em                  #\n";
  printf "#  RBM vs EMD on Information Set Trees (Real Poker Deck)       #\n";
  printf "################################################################\n\n%!";

  (* ================================================================ *)
  (* Configuration                                                     *)
  (* ================================================================ *)

  (* 2 rounds, max 1 raise: each deal subtree has ~33 nodes,
     IS tree = 49 branches x ~33 = ~1667 nodes.
     This gives meaningful tree structure while keeping non-memoized
     pairwise RBM distance tractable for 100 samples. *)
  let config = {
    Rhode_island.deck = Card.full_deck;
    ante = 5;
    bet_sizes = [ 10; 20 ];
    max_raises = 1;
  } in
  let deck = config.deck in
  let n_cards = List.length deck in
  let n_rounds = List.length config.bet_sizes in

  printf "Deck: %d cards (full 52-card deck)\n" n_cards;
  printf "Betting: %d rounds, ante=%d, bets=%s, max_raises=%d\n"
    n_rounds config.ante
    (String.concat ~sep:"/" (List.map config.bet_sizes ~f:Int.to_string))
    config.max_raises;
  printf "Tree type: Information set trees (P1 perspective)\n";
  printf "Distance: NON-memoized RBM (accurate leaf-value comparison)\n";
  printf "Target samples: %d community card pairs\n\n%!" n_samples;

  (* Fix P1's hole card to Ace of spades *)
  let p1_card = { Card.rank = Ace; suit = Spades } in
  printf "P1 hole card: %s (strong starting hand)\n\n%!"
    (Card.to_string p1_card);

  (* Enumerate all (flop, turn) community pairs.
     Remaining deck after removing P1: 51 cards.
     Ordered pairs: 51 x 50 = 2550 *)
  let remaining_after_p1 =
    List.filter deck ~f:(fun c -> not (Card.equal c p1_card))
  in
  let n_remaining = List.length remaining_after_p1 in

  let all_communities =
    List.concat_map remaining_after_p1 ~f:(fun flop ->
      let after_flop =
        List.filter remaining_after_p1 ~f:(fun c -> not (Card.equal c flop))
      in
      List.map after_flop ~f:(fun turn -> (flop, turn)))
  in
  let total_communities = List.length all_communities in
  printf "Remaining cards after P1: %d\n" n_remaining;
  printf "Total ordered communities (flop x turn): %d\n" total_communities;
  printf "Sampling %d communities (%.1f%% of space)\n\n%!"
    n_samples (100.0 *. Float.of_int n_samples /. Float.of_int total_communities);

  (* Sample deterministically *)
  let sampled =
    seeded_shuffle ~seed all_communities
    |> (fun lst -> List.take lst n_samples)
  in
  let n = List.length sampled in

  (* ================================================================ *)
  (* [1] Generate information set trees and EMD distributions          *)
  (* ================================================================ *)
  printf "--- [1] Generating information set trees and EMD distributions ---\n\n%!";

  let (data, gen_time) = time (fun () ->
    List.map sampled ~f:(fun (flop, turn) ->
      let community = [ flop; turn ] in
      let is_tree =
        Rhode_island.information_set_tree ~config ~player:0
          ~hole_card:p1_card ~community
      in
      let emd_dist =
        Emd_baseline.compute_distribution ~deck:config.deck
          ~p1_card ~community
      in
      { flop; turn; is_tree; emd_dist }))
  in
  printf "Generated %d IS trees + EMD distributions in %.3fs\n%!" n gen_time;

  let sample_tree = (List.hd_exn data).is_tree in
  printf "Each IS tree: %d nodes, %d leaves, depth %d\n%!"
    (Tree.size sample_tree) (Tree.num_leaves sample_tree) (Tree.depth sample_tree);
  let n_branches = match sample_tree with
    | Tree.Node { children; _ } -> List.length children
    | Tree.Leaf _ -> 0 in
  printf "  (%d opponent branches x game tree per deal)\n\n%!" n_branches;

  (* Hand category breakdown *)
  let category_counts = Hashtbl.create (module String) in
  List.iter data ~f:(fun d ->
    let cat = hand_category p1_card d.flop d.turn in
    Hashtbl.update category_counts cat ~f:(function
      | None -> 1
      | Some n -> n + 1));
  printf "P1 hand categories (As + community):\n%!";
  Hashtbl.iteri category_counts ~f:(fun ~key ~data ->
    printf "  %-10s: %d communities\n%!" key data);
  printf "\n%!";

  (* Show sample communities *)
  printf "Sample communities (first 20):\n%!";
  printf "  %-4s  %-8s  %-8s  %6s  %6s  %6s  %7s  %7s\n%!"
    "#" "Commun." "Hand" "Win%" "Draw%" "Lose%" "EMD_EV" "Tree_EV";
  List.iteri data ~f:(fun i d ->
    match i < 20 with
    | true ->
      let cat = hand_category p1_card d.flop d.turn in
      printf "  %-4d  %-8s  %-8s  %5.1f%%  %5.1f%%  %5.1f%%  %+.3f  %+.3f\n%!"
        i
        (community_string d)
        cat
        (d.emd_dist.win_prob *. 100.0)
        (d.emd_dist.draw_prob *. 100.0)
        (d.emd_dist.lose_prob *. 100.0)
        d.emd_dist.ev
        (Tree.ev d.is_tree)
    | false -> ());
  (match n > 20 with
   | true -> printf "  ... (%d more)\n%!" (n - 20)
   | false -> ());
  printf "\n%!";

  (* ================================================================ *)
  (* [2] Pairwise distance matrices                                    *)
  (* ================================================================ *)
  printf "--- [2] Pairwise distance matrices ---\n\n%!";

  let trees = List.map data ~f:(fun d -> d.is_tree) in
  let trees_arr = Array.of_list trees in
  let emd_dists_list = List.map data ~f:(fun d -> d.emd_dist) in

  printf "Computing RBM distance matrix (non-memoized, accurate)...\n%!";
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

  (* ================================================================ *)
  (* [3] Distance spectrum analysis                                    *)
  (* ================================================================ *)
  printf "--- [3] Distance spectrum analysis ---\n\n%!";

  let rbm_pw = collect_pairwise_distances rbm_matrix n in
  let emd_pw = collect_pairwise_distances emd_matrix n in
  let ev_pw = collect_pairwise_distances ev_matrix n in

  let n_pairs = n * (n - 1) / 2 in
  let rbm_min, rbm_max, rbm_mean, rbm_std, rbm_distinct = distance_stats rbm_pw in
  let emd_min, emd_max, emd_mean, emd_std, emd_distinct = distance_stats emd_pw in
  let ev_min, ev_max, ev_mean, ev_std, ev_distinct = distance_stats ev_pw in

  printf "Total pairwise distances: %d\n\n%!" n_pairs;
  printf "  %-6s  %10s  %10s  %10s  %10s  %8s\n%!"
    "Method" "Min" "Max" "Mean" "StdDev" "Distinct";
  printf "  %s\n%!" (String.make 62 '-');
  printf "  %-6s  %10.4f  %10.4f  %10.4f  %10.4f  %8d\n%!"
    "RBM" rbm_min rbm_max rbm_mean rbm_std rbm_distinct;
  printf "  %-6s  %10.4f  %10.4f  %10.4f  %10.4f  %8d\n%!"
    "EMD" emd_min emd_max emd_mean emd_std emd_distinct;
  printf "  %-6s  %10.4f  %10.4f  %10.4f  %10.4f  %8d\n\n%!"
    "EV" ev_min ev_max ev_mean ev_std ev_distinct;

  (* Distance distribution: histogram buckets *)
  let histogram dists n_buckets max_val =
    let buckets = Array.create ~len:n_buckets 0 in
    List.iter dists ~f:(fun d ->
      let idx =
        match Float.( > ) max_val 0.0 with
        | true ->
          let bucket = Float.iround_down_exn
            (d /. max_val *. Float.of_int (n_buckets - 1)) in
          Int.min bucket (n_buckets - 1)
        | false -> 0
      in
      buckets.(idx) <- buckets.(idx) + 1);
    buckets
  in

  printf "RBM distance histogram (10 buckets):\n%!";
  let rbm_hist = histogram rbm_pw 10 rbm_max in
  let max_count = Array.fold rbm_hist ~init:1 ~f:Int.max in
  Array.iteri rbm_hist ~f:(fun i count ->
    let lo = Float.of_int i /. 10.0 *. rbm_max in
    let hi = Float.of_int (i + 1) /. 10.0 *. rbm_max in
    let bar_len = count * 50 / max_count in
    printf "  [%8.1f - %8.1f]: %4d %s\n%!" lo hi count
      (String.make bar_len '#'));
  printf "\n%!";

  (* ================================================================ *)
  (* [4] Top-5 closest and farthest community pairs                    *)
  (* ================================================================ *)
  printf "--- [4] Top-5 closest and farthest community pairs ---\n\n%!";

  (* Collect all pairs with distances *)
  let all_pairs = ref [] in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      all_pairs := (i, j, rbm_matrix.(i).(j)) :: !all_pairs
    done
  done;
  let sorted_pairs = List.sort !all_pairs ~compare:(fun (_, _, d1) (_, _, d2) ->
    Float.compare d1 d2) in

  printf "TOP-5 CLOSEST pairs (most similar IS trees):\n%!";
  printf "  %-4s  %-10s  %-10s  %-8s  %-8s  %10s  %8s  %8s  %8s\n%!"
    "Rank" "Comm A" "Comm B" "Hand A" "Hand B" "RBM" "EMD" "EV_A" "EV_B";
  printf "  %s\n%!" (String.make 92 '-');
  List.iteri (List.take sorted_pairs 5) ~f:(fun rank (i, j, rbm_d) ->
    let di = List.nth_exn data i in
    let dj = List.nth_exn data j in
    let emd_d = emd_matrix.(i).(j) in
    printf "  %-4d  %-10s  %-10s  %-8s  %-8s  %10.2f  %8.4f  %+7.3f  %+7.3f\n%!"
      (rank + 1)
      (community_string di) (community_string dj)
      (hand_category p1_card di.flop di.turn)
      (hand_category p1_card dj.flop dj.turn)
      rbm_d emd_d
      (Tree.ev di.is_tree) (Tree.ev dj.is_tree));
  printf "\n%!";

  printf "TOP-5 FARTHEST pairs (most different IS trees):\n%!";
  printf "  %-4s  %-10s  %-10s  %-8s  %-8s  %10s  %8s  %8s  %8s\n%!"
    "Rank" "Comm A" "Comm B" "Hand A" "Hand B" "RBM" "EMD" "EV_A" "EV_B";
  printf "  %s\n%!" (String.make 92 '-');
  let farthest = List.rev sorted_pairs in
  List.iteri (List.take farthest 5) ~f:(fun rank (i, j, rbm_d) ->
    let di = List.nth_exn data i in
    let dj = List.nth_exn data j in
    let emd_d = emd_matrix.(i).(j) in
    printf "  %-4d  %-10s  %-10s  %-8s  %-8s  %10.2f  %8.4f  %+7.3f  %+7.3f\n%!"
      (rank + 1)
      (community_string di) (community_string dj)
      (hand_category p1_card di.flop di.turn)
      (hand_category p1_card dj.flop dj.turn)
      rbm_d emd_d
      (Tree.ev di.is_tree) (Tree.ev dj.is_tree));
  printf "\n%!";

  (* Detailed analysis of closest and farthest *)
  let (ci, cj, cd) = List.hd_exn sorted_pairs in
  let close_i = List.nth_exn data ci in
  let close_j = List.nth_exn data cj in
  printf "Closest pair details:\n%!";
  printf "  Comm A: %s  hand=%s  TreeEV=%+.3f  W/D/L=%.1f/%.1f/%.1f%%\n%!"
    (community_string close_i)
    (hand_category p1_card close_i.flop close_i.turn)
    (Tree.ev close_i.is_tree)
    (close_i.emd_dist.win_prob *. 100.0)
    (close_i.emd_dist.draw_prob *. 100.0)
    (close_i.emd_dist.lose_prob *. 100.0);
  printf "  Comm B: %s  hand=%s  TreeEV=%+.3f  W/D/L=%.1f/%.1f/%.1f%%\n%!"
    (community_string close_j)
    (hand_category p1_card close_j.flop close_j.turn)
    (Tree.ev close_j.is_tree)
    (close_j.emd_dist.win_prob *. 100.0)
    (close_j.emd_dist.draw_prob *. 100.0)
    (close_j.emd_dist.lose_prob *. 100.0);
  printf "  RBM distance: %.4f  EMD distance: %.4f\n\n%!" cd emd_matrix.(ci).(cj);

  let (fi, fj, fd) = List.hd_exn farthest in
  let far_i = List.nth_exn data fi in
  let far_j = List.nth_exn data fj in
  printf "Farthest pair details:\n%!";
  printf "  Comm A: %s  hand=%s  TreeEV=%+.3f  W/D/L=%.1f/%.1f/%.1f%%\n%!"
    (community_string far_i)
    (hand_category p1_card far_i.flop far_i.turn)
    (Tree.ev far_i.is_tree)
    (far_i.emd_dist.win_prob *. 100.0)
    (far_i.emd_dist.draw_prob *. 100.0)
    (far_i.emd_dist.lose_prob *. 100.0);
  printf "  Comm B: %s  hand=%s  TreeEV=%+.3f  W/D/L=%.1f/%.1f/%.1f%%\n%!"
    (community_string far_j)
    (hand_category p1_card far_j.flop far_j.turn)
    (Tree.ev far_j.is_tree)
    (far_j.emd_dist.win_prob *. 100.0)
    (far_j.emd_dist.draw_prob *. 100.0)
    (far_j.emd_dist.lose_prob *. 100.0);
  printf "  RBM distance: %.4f  EMD distance: %.4f\n\n%!" fd emd_matrix.(fi).(fj);

  (* ================================================================ *)
  (* [5] Compression vs Error table                                    *)
  (* ================================================================ *)
  printf "--- [5] Compression vs Error ---\n\n%!";

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

  let (rbm_results, rbm_sweep_t) = time (fun () ->
    sweep_with_matrix rbm_matrix rbm_max)
  in
  let (emd_results, emd_sweep_t) = time (fun () ->
    sweep_with_matrix emd_matrix emd_max)
  in
  let (ev_results, ev_sweep_t) = time (fun () ->
    sweep_with_matrix ev_matrix ev_max)
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
    [ n; 50; 30; 20; 15; 10; 7; 5; 3; 2; 1 ]
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

  printf "  %-8s  %-9s  %-12s  %-12s  %-12s  %-8s\n%!"
    "clusters" "compress" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 73 '-');

  let rbm_wins = ref 0 in
  let emd_wins = ref 0 in
  let ev_wins = ref 0 in
  let ties = ref 0 in

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

    (* Track wins (skip trivial k=n case) *)
    (match target_k = n with
     | true -> ()
     | false ->
       let tol = 0.0001 in
       let candidates = [
         ("RBM", rbm_err);
         ("EMD", emd_err);
         ("EV", ev_err);
       ] |> List.filter ~f:(fun (_, e) -> Float.is_finite e) in
       let min_err = List.fold candidates ~init:Float.infinity
         ~f:(fun acc (_, e) -> Float.min acc e) in
       let all_tied = List.for_all candidates ~f:(fun (_, e) ->
         Float.( < ) (Float.abs (e -. min_err)) tol) in
       match all_tied with
       | true -> Int.incr ties
       | false ->
         let winner_name, _ = List.fold candidates ~init:("", Float.infinity)
           ~f:(fun (bn, be) (name, err) ->
             match Float.( < ) err be with
             | true -> (name, err)
             | false -> (bn, be)) in
         (match String.equal winner_name "RBM" with
          | true -> Int.incr rbm_wins
          | false ->
            match String.equal winner_name "EMD" with
            | true -> Int.incr emd_wins
            | false -> Int.incr ev_wins));

    let winner =
      match target_k = n with
      | true -> "n/a"
      | false ->
        let tol = 0.0001 in
        let candidates = [
          ("RBM", rbm_err); ("EMD", emd_err); ("EV", ev_err);
        ] |> List.filter ~f:(fun (_, e) -> Float.is_finite e) in
        match candidates with
        | [] -> "N/A"
        | _ ->
          let min_err = List.fold candidates ~init:Float.infinity
            ~f:(fun acc (_, e) -> Float.min acc e) in
          let all_tied = List.for_all candidates ~f:(fun (_, e) ->
            Float.( < ) (Float.abs (e -. min_err)) tol) in
          match all_tied with
          | true -> "tie"
          | false ->
            let best_name, _ = List.fold candidates ~init:("", Float.infinity)
              ~f:(fun (bn, be) (name, err) ->
                match Float.( < ) err be with
                | true -> (name, err)
                | false -> (bn, be)) in
            best_name
    in
    printf "  %-8d  %-9s  %-12s  %-12s  %-12s  %-8s\n%!"
      target_k (sprintf "%.1fx" comp) rbm_str emd_str ev_str winner);
  printf "\n%!";

  (* ================================================================ *)
  (* [6] Detailed cluster analysis at moderate compression             *)
  (* ================================================================ *)
  printf "--- [6] Detailed cluster analysis (targeting ~10 clusters) ---\n\n%!";

  let find_eps_for_k ~target_k dist_matrix max_dist =
    let best_eps = ref 0.0 in
    let best_k = ref n in
    for step = 0 to 200 do
      let frac = Float.of_int step /. 200.0 in
      let eps = frac *. max_dist *. 1.1 in
      let clusters = cluster_by_distance_matrix ~epsilon:eps dist_matrix n in
      let k = List.length clusters in
      match Int.abs (k - target_k) < Int.abs (!best_k - target_k) with
      | true -> best_eps := eps; best_k := k
      | false -> ()
    done;
    (!best_eps, !best_k)
  in

  let (rbm_eps_10, _) = find_eps_for_k ~target_k:10 rbm_matrix rbm_max in
  let rbm_clusters_10 = cluster_by_distance_matrix ~epsilon:rbm_eps_10 rbm_matrix n in
  let rbm_k_10 = List.length rbm_clusters_10 in
  let rbm_ev_err_10 = max_ev_error_tree trees_arr rbm_clusters_10 in
  printf "RBM clusters (k=%d, eps=%.2f, ev_err=%.4f):\n%!"
    rbm_k_10 rbm_eps_10 rbm_ev_err_10;
  List.iteri rbm_clusters_10 ~f:(fun ci (member_indices, diam) ->
    let n_members = List.length member_indices in
    let evs = List.map member_indices ~f:(fun i -> Tree.ev trees_arr.(i)) in
    let min_ev = List.fold evs ~init:Float.infinity ~f:Float.min in
    let max_ev = List.fold evs ~init:Float.neg_infinity ~f:Float.max in
    let cats = List.map member_indices ~f:(fun idx ->
      let d = List.nth_exn data idx in
      hand_category p1_card d.flop d.turn) in
    let cat_summary = Hashtbl.create (module String) in
    List.iter cats ~f:(fun c ->
      Hashtbl.update cat_summary c ~f:(function None -> 1 | Some n -> n + 1));
    let cat_str = Hashtbl.to_alist cat_summary
      |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
      |> List.map ~f:(fun (k, v) -> sprintf "%s:%d" k v)
      |> String.concat ~sep:" " in
    printf "  C%d (%d members, diam=%.2f, EV=[%+.3f..%+.3f]): %s\n%!"
      ci n_members diam min_ev max_ev cat_str;
    let first_members = List.take member_indices (Int.min 5 n_members) in
    let member_strs = List.map first_members ~f:(fun idx ->
      let d = List.nth_exn data idx in
      community_string d) in
    printf "    %s%s\n%!"
      (String.concat ~sep:", " member_strs)
      (match n_members > 5 with true -> ", ..." | false -> ""));
  printf "\n%!";

  (* Also show EMD clusters at ~10 for comparison *)
  let (emd_eps_10, _) = find_eps_for_k ~target_k:10 emd_matrix emd_max in
  let emd_clusters_10 = cluster_by_distance_matrix ~epsilon:emd_eps_10 emd_matrix n in
  let emd_k_10 = List.length emd_clusters_10 in
  let emd_ev_err_10 = max_ev_error_tree trees_arr emd_clusters_10 in
  printf "EMD clusters (k=%d, eps=%.4f, ev_err=%.4f):\n%!"
    emd_k_10 emd_eps_10 emd_ev_err_10;
  List.iteri emd_clusters_10 ~f:(fun ci (member_indices, diam) ->
    let n_members = List.length member_indices in
    let evs = List.map member_indices ~f:(fun i -> Tree.ev trees_arr.(i)) in
    let min_ev = List.fold evs ~init:Float.infinity ~f:Float.min in
    let max_ev = List.fold evs ~init:Float.neg_infinity ~f:Float.max in
    let cats = List.map member_indices ~f:(fun idx ->
      let d = List.nth_exn data idx in
      hand_category p1_card d.flop d.turn) in
    let cat_summary = Hashtbl.create (module String) in
    List.iter cats ~f:(fun c ->
      Hashtbl.update cat_summary c ~f:(function None -> 1 | Some n -> n + 1));
    let cat_str = Hashtbl.to_alist cat_summary
      |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
      |> List.map ~f:(fun (k, v) -> sprintf "%s:%d" k v)
      |> String.concat ~sep:" " in
    printf "  C%d (%d members, diam=%.4f, EV=[%+.3f..%+.3f]): %s\n%!"
      ci n_members diam min_ev max_ev cat_str;
    let first_members = List.take member_indices (Int.min 5 n_members) in
    let member_strs = List.map first_members ~f:(fun idx ->
      let d = List.nth_exn data idx in
      community_string d) in
    printf "    %s%s\n%!"
      (String.concat ~sep:", " member_strs)
      (match n_members > 5 with true -> ", ..." | false -> ""));
  printf "\n%!";

  (* ================================================================ *)
  (* [7] Summary                                                       *)
  (* ================================================================ *)
  let t_end = Core_unix.gettimeofday () in
  let total_time = t_end -. t_start in

  printf "--- [7] Summary ---\n\n%!";

  let n_compared = List.length target_ks - 1 in
  printf "Wins across %d compression levels:\n%!" n_compared;
  printf "  RBM: %d wins\n%!" !rbm_wins;
  printf "  EMD: %d wins\n%!" !emd_wins;
  printf "  EV:  %d wins\n%!" !ev_wins;
  printf "  Tie: %d\n\n%!" !ties;

  printf "Distance spectrum richness:\n%!";
  printf "  RBM: %d distinct values (out of %d pairs)\n%!" rbm_distinct n_pairs;
  printf "  EMD: %d distinct values\n%!" emd_distinct;
  printf "  EV:  %d distinct values\n\n%!" ev_distinct;

  printf "Timing breakdown:\n%!";
  printf "  IS tree generation:  %.3fs\n%!" gen_time;
  printf "  RBM distance matrix: %.3fs (non-memoized)\n%!" rbm_time;
  printf "  EMD distance matrix: %.3fs\n%!" emd_time;
  printf "  Compression sweeps:  %.3fs\n%!" (rbm_sweep_t +. emd_sweep_t +. ev_sweep_t);
  printf "  Total runtime:       %.1fs\n\n%!" total_time;

  printf "Key findings:\n%!";
  printf "  - 52-card IS trees: %d nodes each (%d opponent branches)\n%!"
    (Tree.size sample_tree) n_branches;
  printf "  - Distance spectrum: %d distinct RBM values (out of %d pairs)\n%!"
    rbm_distinct n_pairs;
  printf "  - EMD granularity: %d distinct EMD values (49 possible opponents)\n%!"
    emd_distinct;
  printf "  - Each IS tree captures how P1's strategy changes across all\n%!";
  printf "    possible opponents, not just a single deal outcome.\n%!";
  printf "  - Different communities create different hand-strength\n%!";
  printf "    distributions (pairs, flushes, straights) leading to\n%!";
  printf "    structurally different IS trees.\n\n%!";

  printf "Done.\n"
