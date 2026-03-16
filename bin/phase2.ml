open Rbm

(** Phase 2: Mini Texas Hold'em (2 hole cards) RBM vs EMD experiment.

    Bridges Rhode Island Hold'em (1 hole card) and full Texas Hold'em:
    - 2 hole cards per player
    - 3 community cards (flop only)
    - 2 betting rounds (pre-flop, post-flop)
    - 5-card hand evaluation
    - 6-rank deck (2-7) x 4 suits = 24 cards

    Samples diverse (P1 hand, flop) combinations to create genuinely
    different information set trees for clustering comparison. *)

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

(** Describe a 5-card hand category. *)
let hand_category5 p1_cards community =
  let (h1, h2) = p1_cards in
  match community with
  | [ c1; c2; c3 ] ->
    let rank, _kickers = Hand_eval5.evaluate h1 h2 c1 c2 c3 in
    Hand_eval5.Hand_rank.to_string rank
  | _ -> "unknown"

(** Describe P1's starting hand type. *)
let starting_hand_type (h1 : Card.t) (h2 : Card.t) =
  let r1 = Card.Rank.to_int h1.rank in
  let r2 = Card.Rank.to_int h2.rank in
  let suited = Card.Suit.equal h1.suit h2.suit in
  match r1 = r2 with
  | true -> sprintf "pair(%s)" (Card.Rank.to_string h1.rank)
  | false ->
    let connected = Int.abs (r1 - r2) = 1 in
    match suited, connected with
    | true, true -> "suited-conn"
    | true, false -> "suited"
    | false, true -> "offsuit-conn"
    | false, false -> "offsuit"

(** A sampled deal with its IS tree and EMD distribution. *)
type sampled_deal = {
  p1_cards : Card.t * Card.t;
  flop : Card.t list;
  is_tree : Rhode_island.Node_label.t Tree.t;
  emd_dist : Emd_baseline.hand_distribution;
}

(** Format a deal as a compact string. *)
let deal_string d =
  let (h1, h2) = d.p1_cards in
  sprintf "[%s %s]+%s"
    (Card.to_string h1) (Card.to_string h2)
    (String.concat ~sep:"+" (List.map d.flop ~f:Card.to_string))

let () =
  let t_start = Core_unix.gettimeofday () in
  let n_samples = 50 in
  let seed = 42 in

  printf "################################################################\n";
  printf "#  Phase 2: Mini Texas Hold'em (2 Hole Cards)                  #\n";
  printf "#  RBM vs EMD on Information Set Trees                         #\n";
  printf "################################################################\n\n%!";

  (* ================================================================ *)
  (* Configuration                                                     *)
  (* ================================================================ *)

  let config = Mini_holdem.default_config in
  let deck = config.deck in
  let n_cards = List.length deck in
  let n_rounds = List.length config.bet_sizes in

  printf "Deck: %d cards (6 ranks: 2-7, 4 suits)\n" n_cards;
  printf "Hole cards: 2 per player (Texas Hold'em style)\n";
  printf "Community: 3 cards (flop only)\n";
  printf "Betting: %d rounds, ante=%d, bets=%s, max_raises=%d\n"
    n_rounds config.ante
    (String.concat ~sep:"/" (List.map config.bet_sizes ~f:Int.to_string))
    config.max_raises;
  printf "Hand eval: 5-card poker (2 hole + 3 community)\n";
  printf "Distance: NON-memoized RBM + parallel computation\n";
  printf "Target samples: %d deals (diverse starting hands + flops)\n\n%!" n_samples;

  (* Enumerate all possible (P1 hand, flop) combos.
     P1 hand: C(24,2) = 276 possible starting hands.
     For each hand: C(22,3) = 1540 possible flops.
     Total: 276 * 1540 = 425,040 possible deals.
     We sample n_samples from this space. *)
  let all_starting_hands = Mini_holdem.all_pairs deck in
  let n_starting = List.length all_starting_hands in
  printf "Starting hands C(%d,2): %d\n" n_cards n_starting;

  (* Generate all (starting hand, flop) tuples *)
  let all_deals =
    List.concat_map all_starting_hands ~f:(fun (h1, h2) ->
      let remaining = Mini_holdem.remove_cards deck [ h1; h2 ] in
      let arr = Array.of_list remaining in
      let n_rem = Array.length arr in
      let flops = ref [] in
      for i = 0 to n_rem - 3 do
        for j = i + 1 to n_rem - 2 do
          for k = j + 1 to n_rem - 1 do
            flops := ((h1, h2), [ arr.(i); arr.(j); arr.(k) ]) :: !flops
          done
        done
      done;
      !flops)
  in
  let total_deals = List.length all_deals in
  printf "Total (hand, flop) combos: %d\n" total_deals;
  printf "Sampling %d deals (%.2f%% of space)\n\n%!"
    n_samples (100.0 *. Float.of_int n_samples /. Float.of_int total_deals);

  (* Sample deterministically *)
  let sampled_deals =
    seeded_shuffle ~seed all_deals
    |> (fun lst -> List.take lst n_samples)
  in
  let n = List.length sampled_deals in

  (* ================================================================ *)
  (* [1] Generate information set trees and EMD distributions          *)
  (* ================================================================ *)
  printf "--- [1] Generating information set trees and EMD distributions ---\n\n%!";

  let (data, gen_time) = time (fun () ->
    List.map sampled_deals ~f:(fun (p1_cards, flop) ->
      let community = flop in
      let is_tree =
        Mini_holdem.information_set_tree ~config ~player:0
          ~hole_cards:p1_cards ~community
      in
      let emd_dist =
        Emd_baseline_holdem.compute_distribution ~deck:config.deck
          ~p1_cards ~community
      in
      { p1_cards; flop; is_tree; emd_dist }))
  in
  printf "Generated %d IS trees + EMD distributions in %.3fs\n%!" n gen_time;

  let sample_tree = (List.hd_exn data).is_tree in
  printf "Each IS tree: ~%d nodes, ~%d leaves, depth %d\n%!"
    (Tree.size sample_tree) (Tree.num_leaves sample_tree) (Tree.depth sample_tree);
  let n_branches = match sample_tree with
    | Tree.Node { children; _ } -> List.length children
    | Tree.Leaf _ -> 0 in
  printf "  (~%d opponent hand branches x game tree per deal)\n\n%!" n_branches;

  (* Hand category breakdown *)
  let category_counts = Hashtbl.create (module String) in
  List.iter data ~f:(fun d ->
    let cat = hand_category5 d.p1_cards d.flop in
    Hashtbl.update category_counts cat ~f:(function
      | None -> 1
      | Some n -> n + 1));
  printf "P1 made-hand categories:\n%!";
  Hashtbl.iteri category_counts ~f:(fun ~key ~data ->
    printf "  %-18s: %d deals\n%!" key data);
  printf "\n%!";

  (* Starting hand type breakdown *)
  let hand_type_counts = Hashtbl.create (module String) in
  List.iter data ~f:(fun d ->
    let (h1, h2) = d.p1_cards in
    let ht = starting_hand_type h1 h2 in
    Hashtbl.update hand_type_counts ht ~f:(function
      | None -> 1
      | Some n -> n + 1));
  printf "P1 starting hand types:\n%!";
  Hashtbl.iteri hand_type_counts ~f:(fun ~key ~data ->
    printf "  %-18s: %d deals\n%!" key data);
  printf "\n%!";

  (* Show sample deals *)
  printf "Sample deals (first 20):\n%!";
  printf "  %-4s  %-22s  %-14s  %-18s  %6s  %6s  %6s  %7s  %7s\n%!"
    "#" "Deal" "Start" "Made Hand" "Win%" "Draw%" "Lose%" "EMD_EV" "Tree_EV";
  List.iteri data ~f:(fun i d ->
    match i < 20 with
    | true ->
      let (h1, h2) = d.p1_cards in
      let cat = hand_category5 d.p1_cards d.flop in
      let start = starting_hand_type h1 h2 in
      printf "  %-4d  %-22s  %-14s  %-18s  %5.1f%%  %5.1f%%  %5.1f%%  %+.3f  %+.3f\n%!"
        i
        (deal_string d)
        start
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

  let n_pairs = n * (n - 1) / 2 in
  let num_domains = Int.max 1 (Domain.recommended_domain_count () - 1) in

  (* Use fast parallel with pruning *)
  printf "Computing RBM distance matrix (parallel fast, %d domains)...\n%!" num_domains;
  let threshold = 100.0 in
  let ((rbm_matrix, (ev_pr, sh_pr, full_computed)), rbm_time) = time (fun () ->
    Parallel.precompute_distances_parallel_fast ~num_domains ~threshold trees)
  in
  printf "  %dx%d matrix in %.3fs (%d pairs)\n%!" n n rbm_time n_pairs;
  printf "  EV-pruned: %d, Shallow-pruned: %d, Full: %d\n\n%!"
    ev_pr sh_pr full_computed;

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

  let rbm_pw_finite = List.filter rbm_pw ~f:Float.is_finite in
  let rbm_max_finite =
    match rbm_pw_finite with
    | [] -> 1.0
    | _ -> List.last_exn rbm_pw_finite
  in
  let rbm_min_f, _, rbm_mean_f, rbm_std_f, rbm_distinct_f = distance_stats rbm_pw_finite in
  let emd_min, emd_max, emd_mean, emd_std, emd_distinct = distance_stats emd_pw in
  let ev_min, ev_max, ev_mean, ev_std, ev_distinct = distance_stats ev_pw in

  let n_finite = List.length rbm_pw_finite in
  let n_infinite = n_pairs - n_finite in

  printf "Total pairwise distances: %d (finite RBM: %d, EV-pruned: %d)\n\n%!"
    n_pairs n_finite n_infinite;
  printf "  %-6s  %10s  %10s  %10s  %10s  %8s\n%!"
    "Method" "Min" "Max" "Mean" "StdDev" "Distinct";
  printf "  %s\n%!" (String.make 62 '-');
  printf "  %-6s  %10.4f  %10.4f  %10.4f  %10.4f  %8d\n%!"
    "RBM" rbm_min_f rbm_max_finite rbm_mean_f rbm_std_f rbm_distinct_f;
  printf "  %-6s  %10.4f  %10.4f  %10.4f  %10.4f  %8d\n%!"
    "EMD" emd_min emd_max emd_mean emd_std emd_distinct;
  printf "  %-6s  %10.4f  %10.4f  %10.4f  %10.4f  %8d\n\n%!"
    "EV" ev_min ev_max ev_mean ev_std ev_distinct;

  (* Distance histogram *)
  let histogram dists n_buckets max_val =
    let buckets = Array.create ~len:n_buckets 0 in
    List.iter dists ~f:(fun d ->
      let d_capped = Float.min d max_val in
      let idx =
        match Float.( > ) max_val 0.0 with
        | true ->
          let bucket = Float.iround_down_exn
            (d_capped /. max_val *. Float.of_int (n_buckets - 1)) in
          Int.min bucket (n_buckets - 1)
        | false -> 0
      in
      buckets.(idx) <- buckets.(idx) + 1);
    buckets
  in

  printf "RBM distance histogram (10 buckets, finite only):\n%!";
  let rbm_hist = histogram rbm_pw_finite 10 rbm_max_finite in
  let max_count = Array.fold rbm_hist ~init:1 ~f:Int.max in
  Array.iteri rbm_hist ~f:(fun i count ->
    let lo = Float.of_int i /. 10.0 *. rbm_max_finite in
    let hi = Float.of_int (i + 1) /. 10.0 *. rbm_max_finite in
    let bar_len = count * 50 / max_count in
    printf "  [%8.1f - %8.1f]: %4d %s\n%!" lo hi count
      (String.make bar_len '#'));
  printf "\n%!";

  (* ================================================================ *)
  (* [4] Top-5 closest and farthest                                    *)
  (* ================================================================ *)
  printf "--- [4] Top-5 closest and farthest deal pairs ---\n\n%!";

  let all_pairs_list = ref [] in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      all_pairs_list := (i, j, rbm_matrix.(i).(j)) :: !all_pairs_list
    done
  done;
  let finite_pairs = List.filter !all_pairs_list ~f:(fun (_, _, d) ->
    Float.is_finite d) in
  let sorted_pairs = List.sort finite_pairs ~compare:(fun (_, _, d1) (_, _, d2) ->
    Float.compare d1 d2) in

  printf "TOP-5 CLOSEST pairs (most similar IS trees):\n%!";
  printf "  %-4s  %-22s  %-22s  %-14s  %-14s  %10s  %8s\n%!"
    "Rank" "Deal A" "Deal B" "Hand A" "Hand B" "RBM" "EMD";
  printf "  %s\n%!" (String.make 118 '-');
  List.iteri (List.take sorted_pairs 5) ~f:(fun rank (i, j, rbm_d) ->
    let di = List.nth_exn data i in
    let dj = List.nth_exn data j in
    let emd_d = emd_matrix.(i).(j) in
    printf "  %-4d  %-22s  %-22s  %-14s  %-14s  %10.2f  %8.4f\n%!"
      (rank + 1)
      (deal_string di) (deal_string dj)
      (hand_category5 di.p1_cards di.flop)
      (hand_category5 dj.p1_cards dj.flop)
      rbm_d emd_d);
  printf "\n%!";

  printf "TOP-5 FARTHEST pairs (most different IS trees):\n%!";
  printf "  %-4s  %-22s  %-22s  %-14s  %-14s  %10s  %8s\n%!"
    "Rank" "Deal A" "Deal B" "Hand A" "Hand B" "RBM" "EMD";
  printf "  %s\n%!" (String.make 118 '-');
  let farthest = List.rev sorted_pairs in
  List.iteri (List.take farthest 5) ~f:(fun rank (i, j, rbm_d) ->
    let di = List.nth_exn data i in
    let dj = List.nth_exn data j in
    let emd_d = emd_matrix.(i).(j) in
    printf "  %-4d  %-22s  %-22s  %-14s  %-14s  %10.2f  %8.4f\n%!"
      (rank + 1)
      (deal_string di) (deal_string dj)
      (hand_category5 di.p1_cards di.flop)
      (hand_category5 dj.p1_cards dj.flop)
      rbm_d emd_d);
  printf "\n%!";

  (* ================================================================ *)
  (* [5] Compression vs Error table                                    *)
  (* ================================================================ *)
  printf "--- [5] Compression vs Error ---\n\n%!";

  let n_steps = 40 in

  (* For RBM, replace infinity with a large finite value for sweep *)
  let rbm_matrix_for_sweep = Array.init n ~f:(fun i ->
    Array.init n ~f:(fun j ->
      let d = rbm_matrix.(i).(j) in
      match Float.is_finite d with
      | true -> d
      | false -> rbm_max_finite *. 2.0))
  in

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
    sweep_with_matrix rbm_matrix_for_sweep rbm_max_finite)
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

  let target_ks =
    [ n; 40; 30; 25; 20; 15; 10; 7; 5; 3; 2; 1 ]
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
  (* [6] Detailed cluster analysis                                     *)
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

  let (rbm_eps_10, _) =
    find_eps_for_k ~target_k:10 rbm_matrix_for_sweep rbm_max_finite
  in
  let rbm_clusters_10 =
    cluster_by_distance_matrix ~epsilon:rbm_eps_10 rbm_matrix_for_sweep n
  in
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
      hand_category5 d.p1_cards d.flop) in
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
      deal_string d) in
    printf "    %s%s\n%!"
      (String.concat ~sep:", " member_strs)
      (match n_members > 5 with true -> ", ..." | false -> ""));
  printf "\n%!";

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
      hand_category5 d.p1_cards d.flop) in
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
      deal_string d) in
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
  printf "  RBM: %d distinct values (out of %d finite pairs)\n%!" rbm_distinct_f n_finite;
  printf "  EMD: %d distinct values (out of %d pairs)\n%!" emd_distinct n_pairs;
  printf "  EV:  %d distinct values\n\n%!" ev_distinct;

  printf "Timing breakdown:\n%!";
  printf "  IS tree generation:  %.3fs\n%!" gen_time;
  printf "  RBM distance matrix: %.3fs (parallel fast)\n%!" rbm_time;
  printf "  EMD distance matrix: %.3fs\n%!" emd_time;
  printf "  Compression sweeps:  %.3fs\n%!" (rbm_sweep_t +. emd_sweep_t +. ev_sweep_t);
  printf "  Total runtime:       %.1fs\n\n%!" total_time;

  printf "Key findings (Mini Texas Hold'em vs Rhode Island):\n%!";
  printf "  - 2 hole cards -> C(remaining,2) opponent branches (vs C(remaining,1))\n%!";
  printf "  - 5-card hands: pairs, two pair, trips, straights, flushes, full houses\n%!";
  printf "  - Diverse starting hands create structurally distinct IS trees\n%!";
  printf "  - IS trees: ~%d nodes each (~%d opponent branches)\n%!"
    (Tree.size sample_tree) n_branches;
  printf "  - RBM captures strategic differences EMD's flat histogram cannot:\n%!";
  printf "    draw vs made hand, positional betting patterns, raise equity\n%!";

  printf "\nDone.\n"
