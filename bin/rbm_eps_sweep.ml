(* Option (a): does epsilon determine the error rate, and is RBM's
   exploitability-vs-compression curve tighter / more monotone than EMD's?

   On the real Rhode Island game tree (leaves = actual payoffs, so the metric
   bound is on game value, not just equity), sweep the clustering threshold
   epsilon for BOTH metrics, record (epsilon -> #clusters k -> exploitability),
   and overlay the two curves at matched k.

   RBM clusters over Rhode_island.information_set_tree; EMD over the 3-bin
   (lose/draw/win) showdown distribution.

   Usage: rbm-eps-sweep [n_ranks] [cfr_iters] [n_steps] *)

open Rbm

let () =
  let arg i default =
    match List.nth (Sys.get_argv () |> Array.to_list) i with
    | Some s -> Int.of_string s
    | None -> default
  in
  let n_ranks = arg 1 6 in
  let cfr_iters = arg 2 1500 in
  let n_steps = arg 3 40 in
  let max_raises = arg 4 2 in

  let config = {
    Rhode_island.deck = Card.small_deck ~n_ranks;
    ante = 5;
    bet_sizes = [ 10; 10 ];
    max_raises;
  } in
  let deck = config.deck in
  let flop = List.nth_exn deck 0 in
  let turn = List.nth_exn deck (n_ranks * 2) in
  let community = [ flop; turn ] in
  let available =
    List.filter deck ~f:(fun c ->
      not (Card.equal c flop) && not (Card.equal c turn))
  in
  let num_cards = List.length available in

  printf "=== epsilon -> error sweep on real RI game tree ===\n";
  printf "  n_ranks=%d  available_hands=%d  cfr_iters=%d  steps=%d\n"
    n_ranks num_cards cfr_iters n_steps;
  printf "  betting: %d rounds, max_raises=%d\n%!"
    (List.length config.bet_sizes) config.max_raises;

  let is_trees =
    List.map available ~f:(fun card ->
      Rhode_island.information_set_tree ~config ~player:0 ~hole_card:card ~community)
  in
  let rbm_matrix = Ev_graph.precompute_distances is_trees in
  let emd_dists =
    List.map available ~f:(fun card ->
      Emd_baseline.compute_distribution ~deck:config.deck ~p1_card:card ~community)
  in
  let emd_matrix = Emd_baseline.pairwise_emd_matrix emd_dists in

  let (full_p1, full_p2) = Cfr.train ~config ~community ~iterations:cfr_iters in
  let full_exploit = Cfr.exploitability ~config ~community full_p1 full_p2 in
  printf "  full-game (no compression, k=%d) exploitability = %.5f\n%!"
    num_cards full_exploit;

  let max_of m =
    let mx = ref 0.0 in
    for i = 0 to num_cards - 2 do
      for j = i + 1 to num_cards - 1 do
        if Float.is_finite m.(i).(j) && Float.( > ) m.(i).(j) !mx then mx := m.(i).(j)
      done
    done;
    !mx
  in

  (* Sweep epsilon for one metric; return assoc list k -> (exploit, eps_frac)
     keeping the FIRST (smallest) epsilon that yields each distinct k. *)
  let sweep ~name ~matrix =
    let max_dist = max_of matrix in
    let seen = Hashtbl.create (module Int) in
    let rows = ref [] in
    for step = 0 to n_steps do
      let frac = Float.of_int step /. Float.of_int n_steps *. 1.2 in
      let eps = frac *. max_dist in
      let graph = Ev_graph.compress ~epsilon:eps ~precomputed:matrix is_trees in
      let k = List.length graph.clusters in
      if not (Hashtbl.mem seen k) then begin
        Hashtbl.set seen ~key:k ~data:true;
        let (p1, p2, key) =
          Cfr.train_compressed ~config ~community ~ev_graph:graph ~iterations:cfr_iters in
        let exploit = Cfr.exploitability_with_key_fn ~config ~community ~info_key_fn:key p1 p2 in
        rows := (k, exploit, frac) :: !rows
      end
    done;
    let rows = List.sort !rows ~compare:(fun (a, _, _) (b, _, _) -> Int.compare a b) in
    printf "\n  %s curve (max_dist=%.3f):\n" name max_dist;
    printf "    %4s %12s %10s\n" "k" "exploit" "eps_frac";
    List.iter rows ~f:(fun (k, e, f) -> printf "    %4d %12.5f %10.3f\n%!" k e f);
    rows
  in

  let rbm_rows = sweep ~name:"RBM" ~matrix:rbm_matrix in
  let emd_rows = sweep ~name:"EMD" ~matrix:emd_matrix in

  (* Overlay at matched k *)
  let tbl_rbm = Hashtbl.create (module Int) in
  List.iter rbm_rows ~f:(fun (k, e, _) -> Hashtbl.set tbl_rbm ~key:k ~data:e);
  let tbl_emd = Hashtbl.create (module Int) in
  List.iter emd_rows ~f:(fun (k, e, _) -> Hashtbl.set tbl_emd ~key:k ~data:e);
  let all_k =
    (List.map rbm_rows ~f:(fun (k, _, _) -> k) @ List.map emd_rows ~f:(fun (k, _, _) -> k))
    |> List.dedup_and_sort ~compare:Int.compare
  in
  printf "\n  overlay at matched k (lower exploit = tighter abstraction):\n";
  printf "    %4s %12s %12s   %s\n" "k" "RBM" "EMD" "winner";
  printf "    %s\n" (String.make 44 '-');
  let rbm_better = ref 0 and emd_better = ref 0 and ties = ref 0 and both = ref 0 in
  List.iter all_k ~f:(fun k ->
    match Hashtbl.find tbl_rbm k, Hashtbl.find tbl_emd k with
    | Some r, Some e ->
      Int.incr both;
      let w =
        if Float.( < ) (Float.abs (r -. e)) 1e-3 then (Int.incr ties; "tie")
        else if Float.( < ) r e then (Int.incr rbm_better; "RBM")
        else (Int.incr emd_better; "EMD")
      in
      printf "    %4d %12.5f %12.5f   %s\n" k r e w
    | Some r, None -> printf "    %4d %12.5f %12s   (RBM only)\n" k r "-"
    | None, Some e -> printf "    %4d %12s %12.5f   (EMD only)\n" k "-" e
    | None, None -> ());
  printf "\n  matched-k points: %d   RBM tighter: %d   EMD tighter: %d   tie: %d\n%!"
    !both !rbm_better !emd_better !ties;
  printf "\nDone.\n%!"
