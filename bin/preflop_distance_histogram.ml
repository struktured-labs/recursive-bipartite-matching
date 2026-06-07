(** Pairwise RBM showdown-tree distance histogram for all 169 canonical
    preflop Hold'em hands. Outputs CSV (i, j, hand_i, hand_j, distance)
    for downstream plotting and elbow analysis to inform optimal ε
    selection.

    Usage:
      ./preflop_distance_histogram.exe \
        [--output preflop_distances.csv] \
        [--max-opponents 30] \
        [--max-board-samples 20] \
        [--seed 42] *)

open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

let concrete_hole_cards (h : Equity.canonical_hand) : Card.t * Card.t =
  match Card.Rank.equal h.rank1 h.rank2 with
  | true ->
    (Card.create ~rank:h.rank1 ~suit:Card.Suit.Hearts,
     Card.create ~rank:h.rank2 ~suit:Card.Suit.Spades)
  | false ->
    match h.suited with
    | true ->
      (Card.create ~rank:h.rank1 ~suit:Card.Suit.Hearts,
       Card.create ~rank:h.rank2 ~suit:Card.Suit.Hearts)
    | false ->
      (Card.create ~rank:h.rank1 ~suit:Card.Suit.Hearts,
       Card.create ~rank:h.rank2 ~suit:Card.Suit.Diamonds)

let hand_to_string (h : Equity.canonical_hand) =
  let r1 = Card.Rank.to_string h.rank1 in
  let r2 = Card.Rank.to_string h.rank2 in
  match Card.Rank.equal h.rank1 h.rank2 with
  | true -> sprintf "%s%s" r1 r2
  | false ->
    let suit_marker = match h.suited with true -> "s" | false -> "o" in
    sprintf "%s%s%s" r1 r2 suit_marker

let build_showdown_tree ~max_opponents ~max_board_samples
                        (h : Equity.canonical_hand) =
  let (h1, h2) = concrete_hole_cards h in
  let dealt = [ h1; h2 ] in
  let remaining =
    List.filter Card.full_deck ~f:(fun c ->
      not (List.exists dealt ~f:(fun cc -> Card.equal c cc)))
  in
  let rem_arr = Array.of_list remaining in
  let n_rem = Array.length rem_arr in
  let board_children =
    List.init max_board_samples ~f:(fun _ ->
      for i = 0 to Int.min 6 (n_rem - 1) do
        let j = i + Random.int (n_rem - i) in
        let tmp = rem_arr.(i) in
        rem_arr.(i) <- rem_arr.(j);
        rem_arr.(j) <- tmp
      done;
      let board = [
        rem_arr.(0); rem_arr.(1); rem_arr.(2);
        rem_arr.(3); rem_arr.(4);
      ] in
      let opp_start = 5 in
      let n_opp_avail = (n_rem - opp_start) / 2 in
      let n_opps = Int.min max_opponents n_opp_avail in
      for i = opp_start to Int.min (opp_start + n_opps * 2 - 1) (n_rem - 1) do
        let j = i + Random.int (n_rem - i) in
        let tmp = rem_arr.(i) in
        rem_arr.(i) <- rem_arr.(j);
        rem_arr.(j) <- tmp
      done;
      let opp_leaves =
        List.init n_opps ~f:(fun k ->
          let o1 = rem_arr.(opp_start + k * 2) in
          let o2 = rem_arr.(opp_start + k * 2 + 1) in
          let p1h = [ h1; h2 ] @ board in
          let p2h = [ o1; o2 ] @ board in
          let cmp = Hand_eval7.compare_hands7 p1h p2h in
          let value =
            match cmp > 0 with
            | true -> 1.0
            | false ->
              match cmp = 0 with
              | true -> 0.0
              | false -> -1.0
          in
          Tree.leaf
            ~label:(Rhode_island.Node_label.Terminal
                      { winner = None; pot = 0 })
            ~value)
      in
      Tree.node
        ~label:(Rhode_island.Node_label.Chance { description = "board" })
        ~children:opp_leaves)
  in
  Tree.node
    ~label:(Rhode_island.Node_label.Chance {
      description = sprintf "p1=%s%s preflop"
        (Card.to_string h1) (Card.to_string h2);
    })
    ~children:board_children

let () =
  let output_csv = ref "preflop_distances.csv" in
  let max_opponents = ref 30 in
  let max_board_samples = ref 20 in
  let seed = ref 42 in
  let args =
    [ ("--output", Arg.Set_string output_csv,
       "PATH  Output CSV path (default: preflop_distances.csv)");
      ("--max-opponents", Arg.Set_int max_opponents,
       "N  Opponent samples per board (default: 30)");
      ("--max-board-samples", Arg.Set_int max_board_samples,
       "N  Board samples per hand (default: 20)");
      ("--seed", Arg.Set_int seed,
       "N  Random seed (default: 42)");
    ]
  in
  Arg.parse args (fun _ -> ()) "preflop_distance_histogram [options]";
  Random.init !seed;

  let all = Equity.all_canonical_hands in
  let n = List.length all in
  printf "Building %d showdown trees (%d boards × %d opps = %d leaves each)...\n%!"
    n !max_board_samples !max_opponents
    (!max_board_samples * !max_opponents);
  let arr = Array.of_list all in
  let (trees, build_time) = time (fun () ->
    Array.map arr ~f:(build_showdown_tree
      ~max_opponents:!max_opponents
      ~max_board_samples:!max_board_samples))
  in
  printf "  Built in %.2fs\n%!" build_time;

  let n_pairs = n * (n - 1) / 2 in
  printf "Computing %d pairwise RBM distances in parallel...\n%!" n_pairs;
  let tree_list = Array.to_list trees in
  let ((matrix, computed, skipped), dist_time) = time (fun () ->
    Parallel.precompute_distances_parallel_pruned
      ~threshold:1e9 tree_list)
  in
  printf "  Computed in %.2fs (computed=%d, ev_skipped=%d)\n%!"
    dist_time computed skipped;

  let oc = Out_channel.create !output_csv in
  Out_channel.output_string oc "i,j,hand_i,hand_j,distance\n";
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      Out_channel.output_string oc
        (sprintf "%d,%d,%s,%s,%.6f\n"
          i j
          (hand_to_string arr.(i))
          (hand_to_string arr.(j))
          matrix.(i).(j))
    done
  done;
  Out_channel.close oc;
  printf "Wrote %d pairwise distances to %s\n%!" n_pairs !output_csv;

  let pairs = ref [] in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      pairs := matrix.(i).(j) :: !pairs
    done
  done;
  let dists = Array.of_list !pairs in
  Array.sort dists ~compare:Float.compare;
  let m = Array.length dists in
  let pct p =
    dists.(Int.min (m - 1) (Float.to_int (Float.of_int m *. p)))
  in
  printf
    "Distance distribution:\n  min=%.4f  p10=%.4f  p25=%.4f  p50=%.4f  p75=%.4f  p90=%.4f  max=%.4f\n%!"
    dists.(0) (pct 0.10) (pct 0.25) (pct 0.50) (pct 0.75) (pct 0.90)
    dists.(m - 1)
