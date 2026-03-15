(** Earth Mover's Distance baseline for game tree abstraction.

    Standard approach from poker AI literature (Gilpin & Sandholm 2006,
    Ganzfried & Sandholm 2014).  Computes showdown outcome distributions
    and clusters deals by EMD between those distributions. *)

type hand_distribution = {
  win_prob : float;
  lose_prob : float;
  draw_prob : float;
  ev : float;
} [@@deriving sexp]

type deal = {
  p1_card : Card.t;
  community : Card.t list;
}

(* ------------------------------------------------------------------ *)
(* Distribution computation                                            *)
(* ------------------------------------------------------------------ *)

let compute_distribution ~deck ~p1_card ~community =
  (* For each possible opponent card in the remaining deck, determine
     showdown outcome.  Pot size is irrelevant for the distribution;
     we record +1 / 0 / -1 and also accumulate a chip-level EV using
     the standard ante=5 pot (10 chips total). *)
  let remaining =
    List.filter deck ~f:(fun c ->
      (not (Card.equal c p1_card))
      && not (List.exists community ~f:(fun cc -> Card.equal c cc)))
  in
  let n_opp = List.length remaining in
  match n_opp with
  | 0 ->
    { win_prob = 0.0; lose_prob = 0.0; draw_prob = 1.0; ev = 0.0 }
  | _ ->
    let wins = ref 0 in
    let losses = ref 0 in
    let draws = ref 0 in
    List.iter remaining ~f:(fun opp_card ->
      match community with
      | [ flop; turn ] ->
        let cmp =
          Hand_eval.compare_hands
            (p1_card, flop, turn)
            (opp_card, flop, turn)
        in
        (match cmp > 0 with
         | true -> Int.incr wins
         | false ->
           (match cmp < 0 with
            | true -> Int.incr losses
            | false -> Int.incr draws))
      | _ ->
        (* Degenerate: no community or wrong count -> draw *)
        Int.incr draws);
    let n = Float.of_int n_opp in
    let w = Float.of_int !wins in
    let l = Float.of_int !losses in
    let d = Float.of_int !draws in
    (* EV in half-pots: win = +1, draw = 0, lose = -1, then scale by
       the pot/2 baseline.  For a generic metric we keep it unitless. *)
    let ev = (w -. l) /. n in
    { win_prob = w /. n
    ; lose_prob = l /. n
    ; draw_prob = d /. n
    ; ev
    }

let compute_all_distributions ~config ~deals =
  List.map deals ~f:(fun { p1_card; community } ->
    compute_distribution ~deck:config.Rhode_island.deck ~p1_card ~community)

(* ------------------------------------------------------------------ *)
(* Distance metrics                                                    *)
(* ------------------------------------------------------------------ *)

let emd_distance d1 d2 =
  (* 1D Wasserstein on three ordered bins: lose < draw < win.
     CDF at bin boundaries:
       cdf(lose)       = lose_prob
       cdf(lose+draw)  = lose_prob + draw_prob
       cdf(lose+draw+win) = 1.0  (always equal, contributes 0)

     EMD = sum of |cdf1(k) - cdf2(k)| for all interior boundaries. *)
  let cdf1_1 = d1.lose_prob in
  let cdf2_1 = d2.lose_prob in
  let cdf1_2 = d1.lose_prob +. d1.draw_prob in
  let cdf2_2 = d2.lose_prob +. d2.draw_prob in
  Float.abs (cdf1_1 -. cdf2_1) +. Float.abs (cdf1_2 -. cdf2_2)

let ev_distance d1 d2 =
  Float.abs (d1.ev -. d2.ev)

(* ------------------------------------------------------------------ *)
(* Pairwise matrices                                                   *)
(* ------------------------------------------------------------------ *)

let pairwise_matrix ~dist_fn dists =
  let n = List.length dists in
  let arr = Array.of_list dists in
  let m = Array.init n ~f:(fun i ->
    Array.init n ~f:(fun j ->
      match i <= j with
      | true -> dist_fn arr.(i) arr.(j)
      | false -> 0.0))
  in
  (* Fill lower triangle *)
  for i = 0 to n - 1 do
    for j = 0 to i - 1 do
      m.(i).(j) <- m.(j).(i)
    done
  done;
  m

let pairwise_emd_matrix dists = pairwise_matrix ~dist_fn:emd_distance dists
let pairwise_ev_matrix dists = pairwise_matrix ~dist_fn:ev_distance dists

(* ------------------------------------------------------------------ *)
(* Clustering                                                          *)
(* ------------------------------------------------------------------ *)

type emd_cluster = {
  member_indices : int list;
  centroid : hand_distribution;
  diameter : float;
}

type emd_clustering = {
  clusters : emd_cluster list;
  epsilon : float;
  num_original : int;
}

let centroid_of dists indices =
  let n = Float.of_int (List.length indices) in
  match Float.( > ) n 0.0 with
  | false ->
    { win_prob = 0.0; lose_prob = 0.0; draw_prob = 0.0; ev = 0.0 }
  | true ->
    let sum_w = List.sum (module Float) indices
        ~f:(fun i -> dists.(i).win_prob) in
    let sum_l = List.sum (module Float) indices
        ~f:(fun i -> dists.(i).lose_prob) in
    let sum_d = List.sum (module Float) indices
        ~f:(fun i -> dists.(i).draw_prob) in
    let sum_ev = List.sum (module Float) indices
        ~f:(fun i -> dists.(i).ev) in
    { win_prob = sum_w /. n
    ; lose_prob = sum_l /. n
    ; draw_prob = sum_d /. n
    ; ev = sum_ev /. n
    }

let cluster_with_matrix ~epsilon dist_matrix dists =
  let n = Array.length dists in
  (* Single-linkage agglomerative clustering, same algorithm as Ev_graph *)
  let _cluster_of = Array.init n ~f:Fn.id in
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
            (* Single-linkage: min distance between any pair of members *)
            let min_d = ref Float.infinity in
            List.iter members.(ci) ~f:(fun mi ->
              List.iter members.(cj) ~f:(fun mj ->
                let d = dist_matrix.(mi).(mj) in
                (match Float.( < ) d !min_d with
                 | true -> min_d := d
                 | false -> ())));
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
      List.iter members.(cj) ~f:(fun idx -> _cluster_of.(idx) <- ci);
      active.(cj) <- false
    | false ->
      continue := false
  done;

  let clusters =
    Array.to_list
      (Array.filter_mapi active ~f:(fun i is_active ->
         match is_active with
         | true ->
           Some
             { member_indices = members.(i)
             ; centroid = centroid_of dists members.(i)
             ; diameter = diameters.(i)
             }
         | false -> None))
  in
  { clusters; epsilon; num_original = n }

let cluster_by_emd ~epsilon dists =
  let arr = Array.of_list dists in
  let dm = pairwise_emd_matrix dists in
  cluster_with_matrix ~epsilon dm arr

let cluster_by_ev ~epsilon dists =
  let arr = Array.of_list dists in
  let dm = pairwise_ev_matrix dists in
  cluster_with_matrix ~epsilon dm arr

(* ------------------------------------------------------------------ *)
(* Error measurement                                                   *)
(* ------------------------------------------------------------------ *)

let max_ev_error dists clustering =
  let arr = Array.of_list dists in
  List.fold clustering.clusters ~init:0.0 ~f:(fun acc cluster ->
    let centroid_ev = cluster.centroid.ev in
    let cluster_max_err =
      List.fold cluster.member_indices ~init:0.0 ~f:(fun acc idx ->
        Float.max acc (Float.abs (arr.(idx).ev -. centroid_ev)))
    in
    Float.max acc cluster_max_err)

(* ------------------------------------------------------------------ *)
(* Comparison report                                                   *)
(* ------------------------------------------------------------------ *)

let comparison_report ~config ~deals ~trees ?rbm_precomputed () =
  let buf = Buffer.create 1024 in
  let bprintf fmt = Printf.bprintf buf fmt in

  (* Compute EMD distributions *)
  let dists = compute_all_distributions ~config ~deals in
  let emd_matrix = pairwise_emd_matrix dists in
  let ev_matrix = pairwise_ev_matrix dists in

  (* Compute RBM distance matrix *)
  let rbm_matrix =
    match rbm_precomputed with
    | Some m -> m
    | None -> Ev_graph.precompute_distances trees
  in

  let n = List.length trees in
  bprintf "=== EMD Baseline Comparison Report ===\n";
  bprintf "Deals: %d\n\n" n;

  (* Show distributions *)
  bprintf "--- Hand Strength Distributions ---\n";
  bprintf "  %-8s  %6s  %6s  %6s  %6s\n" "Card" "Win%" "Draw%" "Lose%" "EV";
  List.iter2_exn deals dists ~f:(fun deal dist ->
    bprintf "  %-8s  %5.1f%%  %5.1f%%  %5.1f%%  %+.3f\n"
      (Card.to_string deal.p1_card)
      (dist.win_prob *. 100.0)
      (dist.draw_prob *. 100.0)
      (dist.lose_prob *. 100.0)
      dist.ev);
  bprintf "\n";

  (* Run clustering at multiple levels and compare *)
  bprintf "--- Compression vs Max EV Error ---\n";
  bprintf "  %8s  %6s  %10s  %10s  %10s\n"
    "clusters" "comp" "RBM_err" "EMD_err" "EV_err";

  (* Find the range of distances to pick good epsilon values *)
  let max_rbm_dist = ref 0.0 in
  let max_emd_dist = ref 0.0 in
  let max_ev_dist = ref 0.0 in
  for i = 0 to n - 1 do
    for j = i + 1 to n - 1 do
      max_rbm_dist := Float.max !max_rbm_dist rbm_matrix.(i).(j);
      max_emd_dist := Float.max !max_emd_dist emd_matrix.(i).(j);
      max_ev_dist := Float.max !max_ev_dist ev_matrix.(i).(j)
    done
  done;

  (* Sweep epsilon for each method and report at matching cluster counts *)
  let rbm_results = ref [] in
  let emd_results = ref [] in
  let ev_results = ref [] in

  let n_steps = 20 in
  for step = 0 to n_steps do
    let frac = Float.of_int step /. Float.of_int n_steps in

    (* RBM *)
    let rbm_eps = frac *. !max_rbm_dist *. 1.1 in
    let rbm_graph =
      Ev_graph.compress ~epsilon:rbm_eps ~precomputed:rbm_matrix trees
    in
    let rbm_nclusters = List.length rbm_graph.clusters in
    let rbm_ev_err = Ev_graph.ev_error rbm_graph in
    rbm_results := (rbm_nclusters, rbm_ev_err) :: !rbm_results;

    (* EMD *)
    let emd_eps = frac *. !max_emd_dist *. 1.1 in
    let emd_arr = Array.of_list dists in
    let emd_clustering =
      cluster_with_matrix ~epsilon:emd_eps emd_matrix emd_arr
    in
    let emd_nclusters = List.length emd_clustering.clusters in
    let emd_ev_err = max_ev_error dists emd_clustering in
    emd_results := (emd_nclusters, emd_ev_err) :: !emd_results;

    (* Scalar EV *)
    let ev_eps = frac *. !max_ev_dist *. 1.1 in
    let ev_clustering =
      cluster_with_matrix ~epsilon:ev_eps ev_matrix emd_arr
    in
    let ev_nclusters = List.length ev_clustering.clusters in
    let ev_ev_err = max_ev_error dists ev_clustering in
    ev_results := (ev_nclusters, ev_ev_err) :: !ev_results
  done;

  (* Deduplicate by cluster count, keeping the best (lowest) error for each *)
  let best_at_k tbl =
    let h = Hashtbl.create (module Int) in
    List.iter tbl ~f:(fun (k, err) ->
      Hashtbl.update h k ~f:(function
        | None -> err
        | Some prev -> Float.min prev err));
    Hashtbl.to_alist h
    |> List.sort ~compare:(fun (k1, _) (k2, _) -> Int.compare k2 k1)
  in

  let rbm_by_k = best_at_k !rbm_results in
  let emd_by_k = best_at_k !emd_results in
  let ev_by_k = best_at_k !ev_results in

  (* For each cluster count that appears in at least one method, report *)
  let all_ks =
    List.map rbm_by_k ~f:fst
    @ List.map emd_by_k ~f:fst
    @ List.map ev_by_k ~f:fst
    |> List.dedup_and_sort ~compare:Int.compare
    |> List.rev
  in

  let lookup_err tbl k =
    match List.Assoc.find tbl k ~equal:Int.equal with
    | Some e -> sprintf "%10.4f" e
    | None -> sprintf "%10s" "-"
  in

  List.iter all_ks ~f:(fun k ->
    let comp =
      match k > 0 with
      | true -> Float.of_int n /. Float.of_int k
      | false -> Float.infinity
    in
    bprintf "  %8d  %5.1fx  %s  %s  %s\n"
      k comp
      (lookup_err rbm_by_k k)
      (lookup_err emd_by_k k)
      (lookup_err ev_by_k k));

  bprintf "\n";

  (* Summary: at specific cluster counts, show which method wins *)
  bprintf "--- Summary ---\n";
  let interesting_ks =
    List.filter all_ks ~f:(fun k -> k > 1 && k < n)
  in
  List.iter interesting_ks ~f:(fun k ->
    let rbm_e = List.Assoc.find rbm_by_k k ~equal:Int.equal in
    let emd_e = List.Assoc.find emd_by_k k ~equal:Int.equal in
    let ev_e = List.Assoc.find ev_by_k k ~equal:Int.equal in
    let winner =
      let candidates =
        [ ("RBM", rbm_e); ("EMD", emd_e); ("EV", ev_e) ]
        |> List.filter_map ~f:(fun (name, opt) ->
             Option.map opt ~f:(fun e -> (name, e)))
      in
      match candidates with
      | [] -> "N/A"
      | _ ->
        let best_name, _ =
          List.fold candidates ~init:("", Float.infinity)
            ~f:(fun (bn, be) (name, err) ->
              match Float.( < ) err be with
              | true -> (name, err)
              | false -> (bn, be))
        in
        best_name
    in
    bprintf "  k=%d: best method = %s\n" k winner);

  Buffer.contents buf
