open Rbm

(** RBM vs EMD comparison with varied community cards.

    Instead of fixing community cards (which creates degenerate 3-cluster
    structure), we vary (opponent, flop, turn) to create genuine strategic
    diversity: flush draws, straight draws, high-card vs pair boards, etc.

    For each sampled deal (p1_card=fixed, flop, turn), we build:
    - An information-set game tree (averaging over all opponent cards)
    - An EMD hand-strength distribution (win/lose/draw over opponents)

    Then we compare RBM distance vs EMD distance for clustering. *)

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

(** Distance statistics for a set of pairwise distances. *)
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

(** Simple deterministic shuffle using a seed-based LCG. *)
let seeded_shuffle ~seed lst =
  let arr = Array.of_list lst in
  let n = Array.length arr in
  let state = ref seed in
  for i = n - 1 downto 1 do
    (* LCG: state = (state * 1103515245 + 12345) mod 2^31 *)
    state := (!state * 1103515245 + 12345) land 0x7FFFFFFF;
    let j = !state mod (i + 1) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done;
  Array.to_list arr

let () =
  let n_ranks = 3 in
  let n_samples = 50 in
  let seed = 42 in

  printf "=== RBM vs EMD Comparison (varied community cards) ===\n";
  printf "Deck: %d-rank (%d cards), P1 holds: 2c\n" n_ranks (n_ranks * 4);
  printf "Sampling %d deals from enumeration\n\n%!" n_samples;

  let config = Rhode_island.small_config ~n_ranks in
  let deck = config.deck in
  printf "Deck: %s\n%!"
    (String.concat ~sep:" " (List.map deck ~f:Card.to_string));

  (* Fix P1's hole card to 2c (first card in deck) *)
  let p1_card = List.hd_exn deck in
  printf "P1 hole card: %s\n\n%!" (Card.to_string p1_card);

  (* Enumerate all (flop, turn) community combinations from remaining deck.
     For each community, we build an information-set tree that averages
     over all possible opponent cards. *)
  let remaining_after_p1 =
    List.filter deck ~f:(fun c -> not (Card.equal c p1_card))
  in

  (* All (flop, turn) pairs from remaining 11 cards = 11*10 = 110 *)
  let all_communities =
    List.concat_map remaining_after_p1 ~f:(fun flop ->
      let after_flop =
        List.filter remaining_after_p1 ~f:(fun c -> not (Card.equal c flop))
      in
      List.map after_flop ~f:(fun turn -> (flop, turn)))
  in
  printf "Total (flop, turn) communities: %d\n%!" (List.length all_communities);

  (* Sample deterministically *)
  let sampled =
    seeded_shuffle ~seed all_communities
    |> (fun lst -> List.take lst n_samples)
  in
  let n_actual = List.length sampled in
  printf "Sampled: %d communities\n\n%!" n_actual;

  (* For each sampled community, build:
     1. An information-set tree (for RBM distance)
     2. An EMD hand-strength distribution (for EMD distance) *)
  printf "--- [1] Generating game trees and distributions ---\n\n%!";

  let (data, gen_time) = time (fun () ->
    List.map sampled ~f:(fun (flop, turn) ->
      let community = [ flop; turn ] in
      (* Information-set tree: averages over all opponent cards *)
      let tree =
        Rhode_island.information_set_tree ~config ~player:0
          ~hole_card:p1_card ~community
      in
      (* EMD distribution: win/lose/draw over opponent cards *)
      let dist =
        Emd_baseline.compute_distribution ~deck:config.deck
          ~p1_card ~community
      in
      let deal = { Emd_baseline.p1_card; community } in
      (flop, turn, tree, dist, deal)))
  in
  printf "Generated %d trees + distributions in %.3fs\n%!" n_actual gen_time;

  let sample_tree = let (_, _, t, _, _) = List.hd_exn data in t in
  printf "Each info-set tree: %d nodes, %d leaves, depth %d\n\n%!"
    (Tree.size sample_tree) (Tree.num_leaves sample_tree) (Tree.depth sample_tree);

  (* Show first 15 distributions *)
  printf "Sample distributions (first 15):\n%!";
  printf "  %-12s  %6s  %6s  %6s  %7s\n%!" "Community" "Win%" "Draw%" "Lose%" "EV";
  List.iteri data ~f:(fun i (flop, turn, _, dist, _) ->
    match i < 15 with
    | true ->
      printf "  %-12s  %5.1f%%  %5.1f%%  %5.1f%%  %+.3f\n%!"
        (Card.to_string flop ^ " " ^ Card.to_string turn)
        (dist.win_prob *. 100.0)
        (dist.draw_prob *. 100.0)
        (dist.lose_prob *. 100.0)
        dist.ev
    | false -> ());
  (match n_actual > 15 with
   | true -> printf "  ... (%d more)\n%!" (n_actual - 15)
   | false -> ());
  printf "\n%!";

  (* ================================================================ *)
  (* Compute pairwise distance matrices                               *)
  (* ================================================================ *)
  printf "--- [2] Pairwise distance matrices ---\n\n%!";

  let trees = List.map data ~f:(fun (_, _, t, _, _) -> t) in
  let dists = List.map data ~f:(fun (_, _, _, d, _) -> d) in

  let (rbm_matrix, rbm_time) = time (fun () ->
    Ev_graph.precompute_distances trees)
  in
  printf "RBM distance matrix: %dx%d computed in %.3fs\n%!" n_actual n_actual rbm_time;

  let (emd_matrix, emd_time) = time (fun () ->
    Emd_baseline.pairwise_emd_matrix dists)
  in
  printf "EMD distance matrix: %dx%d computed in %.3fs\n%!" n_actual n_actual emd_time;

  let (ev_matrix, ev_time) = time (fun () ->
    Emd_baseline.pairwise_ev_matrix dists)
  in
  printf "EV distance matrix:  %dx%d computed in %.3fs\n\n%!" n_actual n_actual ev_time;

  (* Distance statistics *)
  let rbm_dists = collect_pairwise_distances rbm_matrix n_actual in
  let emd_dists = collect_pairwise_distances emd_matrix n_actual in
  let ev_dists = collect_pairwise_distances ev_matrix n_actual in

  let rbm_min, rbm_max, rbm_mean, rbm_distinct = distance_stats rbm_dists in
  let emd_min, emd_max, emd_mean, emd_distinct = distance_stats emd_dists in
  let ev_min, ev_max, ev_mean, ev_distinct = distance_stats ev_dists in

  printf "Distance statistics:\n%!";
  printf "  RBM: min=%.2f max=%.2f mean=%.2f distinct=%d\n%!"
    rbm_min rbm_max rbm_mean rbm_distinct;
  printf "  EMD: min=%.4f max=%.4f mean=%.4f distinct=%d\n%!"
    emd_min emd_max emd_mean emd_distinct;
  printf "  EV:  min=%.4f max=%.4f mean=%.4f distinct=%d\n\n%!"
    ev_min ev_max ev_mean ev_distinct;

  (* ================================================================ *)
  (* Cluster at target counts, compare error                          *)
  (* ================================================================ *)
  printf "--- [3] Compression vs Error ---\n\n%!";

  (* Sweep epsilon values densely for each method *)
  let n_steps = 50 in

  let sweep_rbm () =
    let results = ref [] in
    for step = 0 to n_steps do
      let frac = Float.of_int step /. Float.of_int n_steps in
      let eps = frac *. rbm_max *. 1.1 in
      let graph =
        Ev_graph.compress ~epsilon:eps ~precomputed:rbm_matrix trees
      in
      let k = List.length graph.clusters in
      let err = Ev_graph.ev_error graph in
      results := (k, err) :: !results
    done;
    !results
  in
  let sweep_emd () =
    let results = ref [] in
    let arr = Array.of_list dists in
    for step = 0 to n_steps do
      let frac = Float.of_int step /. Float.of_int n_steps in
      let eps = frac *. emd_max *. 1.1 in
      let clustering =
        Emd_baseline.cluster_by_emd ~epsilon:eps dists
      in
      let k = List.length clustering.clusters in
      let err = Emd_baseline.max_ev_error (Array.to_list arr) clustering in
      results := (k, err) :: !results
    done;
    !results
  in
  let sweep_ev () =
    let results = ref [] in
    let arr = Array.of_list dists in
    for step = 0 to n_steps do
      let frac = Float.of_int step /. Float.of_int n_steps in
      let eps = frac *. ev_max *. 1.1 in
      let clustering =
        Emd_baseline.cluster_by_ev ~epsilon:eps dists
      in
      let k = List.length clustering.clusters in
      let err = Emd_baseline.max_ev_error (Array.to_list arr) clustering in
      results := (k, err) :: !results
    done;
    !results
  in

  let (rbm_results, _) = time sweep_rbm in
  let (emd_results, _) = time sweep_emd in
  let (ev_results, _) = time sweep_ev in

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

  (* Target cluster counts for the table *)
  let target_ks = [ n_actual; 25; 20; 15; 10; 7; 5; 3; 2; 1 ]
    |> List.filter ~f:(fun k -> k <= n_actual)
    |> List.dedup_and_sort ~compare:Int.compare
    |> List.rev
  in

  (* For each target k, find the closest actual k in each method *)
  let find_closest_k by_k target =
    List.fold by_k ~init:(None : (int * float) option)
      ~f:(fun best (k, err) ->
        let dist = Int.abs (k - target) in
        match best with
        | None -> Some (k, err)
        | Some (bk, _berr) ->
          let bdist = Int.abs (bk - target) in
          match dist < bdist with
          | true -> Some (k, err)
          | false ->
            (* Prefer the one with more clusters if tie *)
            match dist = bdist with
            | true ->
              (match Int.abs (k - target) < Int.abs (bk - target) with
               | true -> Some (k, err)
               | false -> best)
            | false -> best)
  in

  printf "  %-8s  %-9s  %-10s  %-10s  %-10s  %-8s\n%!"
    "clusters" "compress" "RBM_err" "EMD_err" "EV_err" "Winner";

  List.iter target_ks ~f:(fun target_k ->
    let rbm_entry = find_closest_k rbm_by_k target_k in
    let emd_entry = find_closest_k emd_by_k target_k in
    let ev_entry = find_closest_k ev_by_k target_k in

    let comp = Float.of_int n_actual /. Float.of_int (Int.max 1 target_k) in

    let format_entry entry =
      match entry with
      | None -> ("-", Float.infinity)
      | Some (k, err) ->
        match k = target_k with
        | true -> (sprintf "%.4f" err, err)
        | false -> (sprintf "%.4f(%d)" err k, err)
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
    printf "  %-8d  %-9s  %-10s  %-10s  %-10s  %-8s\n%!"
      target_k (sprintf "%.1fx" comp) rbm_str emd_str ev_str winner);
  printf "\n%!";

  (* ================================================================ *)
  (* Detailed comparison at interesting compression levels            *)
  (* ================================================================ *)
  printf "--- [4] Detailed cluster analysis ---\n\n%!";

  (* Pick a moderate compression: ~5 clusters *)
  let find_epsilon_for_k ~target_k by_k_results max_dist =
    (* Find the epsilon that yields closest to target_k clusters *)
    let best_eps = ref 0.0 in
    let best_k = ref n_actual in
    for step = 0 to 100 do
      let frac = Float.of_int step /. 100.0 in
      let eps = frac *. max_dist *. 1.1 in
      (* Find what k this epsilon produces from our results *)
      let matching =
        List.filter by_k_results ~f:(fun (k, _) ->
          Int.abs (k - target_k) < Int.abs (!best_k - target_k)
          || (Int.abs (k - target_k) = Int.abs (!best_k - target_k)
              && Float.( < ) eps !best_eps))
      in
      (match matching with
       | [] -> ()
       | _ ->
         let _ = eps in
         ())
    done;
    (* Actually just sweep and pick *)
    let _ = !best_eps in
    let _ = !best_k in
    let best = ref (0.0, n_actual) in
    for step = 0 to 200 do
      let frac = Float.of_int step /. 200.0 in
      let eps = frac *. max_dist *. 1.1 in
      let graph =
        Ev_graph.compress ~epsilon:eps ~precomputed:rbm_matrix trees
      in
      let k = List.length graph.clusters in
      let (_, prev_k) = !best in
      match Int.abs (k - target_k) < Int.abs (prev_k - target_k) with
      | true -> best := (eps, k)
      | false -> ()
    done;
    fst !best
  in

  (* Show RBM clusters at ~5 clusters *)
  let rbm_eps_5 = find_epsilon_for_k ~target_k:5 rbm_results rbm_max in
  let rbm_graph_5 =
    Ev_graph.compress ~epsilon:rbm_eps_5 ~precomputed:rbm_matrix trees
  in
  let rbm_k_5 = List.length rbm_graph_5.clusters in
  printf "RBM clusters (k=%d, eps=%.2f):\n%!" rbm_k_5 rbm_eps_5;
  List.iteri rbm_graph_5.clusters ~f:(fun ci cluster ->
    let member_strs = List.map cluster.members ~f:(fun (idx, _) ->
      let (flop, turn, _, _, _) = List.nth_exn data idx in
      Card.to_string flop ^ "+" ^ Card.to_string turn)
    in
    let n_members = List.length cluster.members in
    let evs = List.map cluster.members ~f:(fun (_, t) -> Tree.ev t) in
    let min_ev = List.fold evs ~init:Float.infinity ~f:Float.min in
    let max_ev = List.fold evs ~init:Float.neg_infinity ~f:Float.max in
    printf "  C%d (%d members, diam=%.1f, EV=[%.1f..%.1f]):\n%!"
      ci n_members cluster.diameter min_ev max_ev;
    (* Show members, wrapping at reasonable width *)
    printf "    %s\n%!" (String.concat ~sep:", " member_strs));
  printf "\n%!";

  (* Show EMD clusters at ~5 clusters *)
  let emd_eps_5 =
    (* Sweep for EMD *)
    let best = ref (0.0, n_actual) in
    for step = 0 to 200 do
      let frac = Float.of_int step /. 200.0 in
      let eps = frac *. emd_max *. 1.1 in
      let clustering = Emd_baseline.cluster_by_emd ~epsilon:eps dists in
      let k = List.length clustering.clusters in
      let (_, prev_k) = !best in
      match Int.abs (k - 5) < Int.abs (prev_k - 5) with
      | true -> best := (eps, k)
      | false -> ()
    done;
    fst !best
  in
  let emd_clustering_5 = Emd_baseline.cluster_by_emd ~epsilon:emd_eps_5 dists in
  let emd_k_5 = List.length emd_clustering_5.clusters in
  printf "EMD clusters (k=%d, eps=%.4f):\n%!" emd_k_5 emd_eps_5;
  List.iteri emd_clustering_5.clusters ~f:(fun ci cluster ->
    let member_strs = List.map cluster.member_indices ~f:(fun idx ->
      let (flop, turn, _, _, _) = List.nth_exn data idx in
      Card.to_string flop ^ "+" ^ Card.to_string turn)
    in
    let n_members = List.length cluster.member_indices in
    let member_evs = List.map cluster.member_indices ~f:(fun idx ->
      let (_, _, _, d, _) = List.nth_exn data idx in
      d.ev)
    in
    let min_ev = List.fold member_evs ~init:Float.infinity ~f:Float.min in
    let max_ev = List.fold member_evs ~init:Float.neg_infinity ~f:Float.max in
    printf "  C%d (%d members, diam=%.4f, EV=[%+.3f..%+.3f]):\n%!"
      ci n_members cluster.diameter min_ev max_ev;
    printf "    %s\n%!" (String.concat ~sep:", " member_strs));
  printf "\n%!";

  (* ================================================================ *)
  (* Summary                                                          *)
  (* ================================================================ *)
  printf "--- [5] Summary ---\n\n%!";

  (* Count wins at each k *)
  let rbm_wins = ref 0 in
  let emd_wins = ref 0 in
  let ev_wins = ref 0 in
  let ties = ref 0 in

  List.iter target_ks ~f:(fun target_k ->
    match target_k = n_actual with
    | true -> () (* skip trivial case *)
    | false ->
      let rbm_err = Option.map (find_closest_k rbm_by_k target_k)
          ~f:snd |> Option.value ~default:Float.infinity in
      let emd_err = Option.map (find_closest_k emd_by_k target_k)
          ~f:snd |> Option.value ~default:Float.infinity in
      let ev_err = Option.map (find_closest_k ev_by_k target_k)
          ~f:snd |> Option.value ~default:Float.infinity in
      let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
      let eps = 0.0001 in
      match Float.( < ) (Float.abs (rbm_err -. emd_err)) eps
            && Float.( < ) (Float.abs (rbm_err -. ev_err)) eps with
      | true -> Int.incr ties
      | false ->
        match Float.( < ) (Float.abs (rbm_err -. min_err)) eps with
        | true -> Int.incr rbm_wins
        | false ->
          match Float.( < ) (Float.abs (emd_err -. min_err)) eps with
          | true -> Int.incr emd_wins
          | false -> Int.incr ev_wins);

  printf "Wins across %d compression levels (excluding trivial k=%d):\n%!"
    (List.length target_ks - 1) n_actual;
  printf "  RBM: %d wins\n%!" !rbm_wins;
  printf "  EMD: %d wins\n%!" !emd_wins;
  printf "  EV:  %d wins\n%!" !ev_wins;
  printf "  Tie: %d\n\n%!" !ties;

  printf "Key insight: With varied community cards, each (flop, turn) creates\n\
         genuinely different strategic situations (pairs on board, flush\n\
         possibilities, different relative hand strengths). RBM captures\n\
         the STRUCTURAL differences in the game tree (how the betting\n\
         strategies differ), while EMD only sees the showdown outcome\n\
         distribution. Two boards can have similar win rates but very\n\
         different optimal strategies.\n\n%!";

  printf "Done.\n"
