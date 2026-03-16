(** RBM vs EMD comparison on full 2-player heads-up Limit Hold'em.
    The definitive experiment: 52-card deck, 2 hole cards, 5 community
    cards, 4 betting rounds.  This is the game Bowling et al. solved.

    Part 1: Preflop abstraction quality comparison
      - Sample 50 canonical starting hands (from the 169)
      - Build IS trees via [Limit_holdem.information_set_tree]
      - RBM: pairwise distance matrix with EV pruning (parallel)
      - EMD: equity distribution distance
      - Scalar EV: |equity1 - equity2|
      - Cluster at multiple k, compare max EV error

    Part 2: MCCFR head-to-head
      - Train 50K iterations with RBM-based bucketing (10 buckets)
      - Train 50K iterations with equity-based bucketing (10 buckets)
      - Self-play 10K hands, report bb/hand

    Usage:
      ./holdem_compare.exe [--n-hands 50] [--mccfr-iters 50000]
                           [--play-hands 10000] [--buckets 10]
                           [--max-opponents 30] *)

open Rbm

(* ------------------------------------------------------------------ *)
(* Timing utility                                                      *)
(* ------------------------------------------------------------------ *)

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

(* ------------------------------------------------------------------ *)
(* Card / deck utilities                                               *)
(* ------------------------------------------------------------------ *)

let shuffle_array arr =
  let n = Array.length arr in
  for i = n - 1 downto 1 do
    let j = Random.int (i + 1) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done

let sample_deal () =
  let deck = Array.of_list Card.full_deck in
  shuffle_array deck;
  let p1 = (deck.(0), deck.(1)) in
  let p2 = (deck.(2), deck.(3)) in
  let board = [ deck.(4); deck.(5); deck.(6); deck.(7); deck.(8) ] in
  (p1, p2, board)

(* ------------------------------------------------------------------ *)
(* Deterministic subsample of canonical hands                          *)
(* ------------------------------------------------------------------ *)

(** Select [n] canonical hands from the 169, deterministically spread
    across the equity range via stride sampling on the sorted list. *)
let sample_canonical_hands ~n ~preflop_eq =
  let all = Equity.all_canonical_hands in
  let total = List.length all in
  let arr = Array.of_list all in
  (* Pair each canonical hand with its precomputed equity *)
  let equities = Array.map arr ~f:(fun (h : Equity.canonical_hand) ->
    (h, preflop_eq.(h.id)))
  in
  Array.sort equities ~compare:(fun (_, e1) (_, e2) -> Float.compare e1 e2);
  let take = Int.min n total in
  let stride = Float.of_int total /. Float.of_int take in
  Array.init take ~f:(fun i ->
    let idx = Int.min (total - 1) (Float.to_int (Float.of_int i *. stride)) in
    equities.(idx))

(* ------------------------------------------------------------------ *)
(* Concrete hole cards for a canonical hand                            *)
(* ------------------------------------------------------------------ *)

let concrete_hole_cards (h : Equity.canonical_hand) : Card.t * Card.t =
  match Card.Rank.equal h.rank1 h.rank2 with
  | true ->
    ({ Card.rank = h.rank1; suit = Card.Suit.Hearts },
     { Card.rank = h.rank2; suit = Card.Suit.Spades })
  | false ->
    match h.suited with
    | true ->
      ({ Card.rank = h.rank1; suit = Card.Suit.Hearts },
       { Card.rank = h.rank2; suit = Card.Suit.Hearts })
    | false ->
      ({ Card.rank = h.rank1; suit = Card.Suit.Hearts },
       { Card.rank = h.rank2; suit = Card.Suit.Diamonds })

(* ------------------------------------------------------------------ *)
(* Fast preflop equity (fewer MC samples for speed)                    *)
(* ------------------------------------------------------------------ *)

let fast_preflop_equities ~n_samples =
  let n = List.length Equity.all_canonical_hands in
  let equities = Array.create ~len:n 0.0 in
  let deck = Array.of_list Card.full_deck in
  List.iter Equity.all_canonical_hands ~f:(fun (hand : Equity.canonical_hand) ->
    let (h1, h2) = concrete_hole_cards hand in
    let remaining =
      Array.filter deck ~f:(fun c ->
        not (Card.equal c h1) && not (Card.equal c h2))
    in
    let n_rem = Array.length remaining in
    let wins = ref 0.0 in
    let total = ref 0 in
    for _ = 1 to n_samples do
      for i = n_rem - 1 downto 1 do
        let j = Random.int (i + 1) in
        let tmp = remaining.(i) in
        remaining.(i) <- remaining.(j);
        remaining.(j) <- tmp
      done;
      let b = Array.sub remaining ~pos:0 ~len:5 in
      let cmp = Equity.compare_7card
          (h1, h2, b.(0), b.(1), b.(2), b.(3), b.(4))
          (remaining.(5), remaining.(6), b.(0), b.(1), b.(2), b.(3), b.(4))
      in
      Int.incr total;
      match cmp > 0 with
      | true -> wins := !wins +. 1.0
      | false ->
        match cmp = 0 with
        | true -> wins := !wins +. 0.5
        | false -> ()
    done;
    equities.(hand.id) <- !wins /. Float.of_int !total);
  equities

(** Build fast preflop abstraction with reduced MC samples. *)
let fast_preflop_abstraction ~n_buckets ~n_samples =
  let equities = fast_preflop_equities ~n_samples in
  let assignments, centroids =
    Abstraction.quantile_bucketing ~n_buckets equities
  in
  ({ Abstraction.street = Preflop; n_buckets; assignments; centroids }
    : Abstraction.abstraction_partial)

(* ------------------------------------------------------------------ *)
(* EMD distance for preflop: equity distribution over boards           *)
(* ------------------------------------------------------------------ *)

(** Compute a preflop equity distribution histogram for a canonical hand.
    Samples random boards (5 cards) and for each computes hand strength
    vs all opponents.  Bins results into [n_bins] buckets in [0,1]. *)
let preflop_equity_distribution ~n_bins ~n_board_samples
    (h : Equity.canonical_hand) =
  let (h1, h2) = concrete_hole_cards h in
  let histogram = Array.create ~len:n_bins 0.0 in
  let deck_arr = Array.of_list Card.full_deck in
  let remaining =
    Array.filter deck_arr ~f:(fun c ->
      not (Card.equal c h1) && not (Card.equal c h2))
  in
  let n_rem = Array.length remaining in
  for _ = 1 to n_board_samples do
    (* Shuffle and take first 5 as board *)
    for i = n_rem - 1 downto 1 do
      let j = Random.int (i + 1) in
      let tmp = remaining.(i) in
      remaining.(i) <- remaining.(j);
      remaining.(j) <- tmp
    done;
    let board = Array.to_list (Array.sub remaining ~pos:0 ~len:5) in
    (* Compute hand strength on this board against sampled opponents *)
    let eq = Equity.hand_strength ~hole_cards:(h1, h2) ~board in
    let bin = Int.min (n_bins - 1)
        (Float.to_int (eq *. Float.of_int n_bins)) in
    histogram.(bin) <- histogram.(bin) +. 1.0
  done;
  let total = Float.of_int n_board_samples in
  Array.iteri histogram ~f:(fun i v -> histogram.(i) <- v /. total);
  histogram

(* ------------------------------------------------------------------ *)
(* Agglomerative clustering on a distance matrix                       *)
(* ------------------------------------------------------------------ *)

(** Single-linkage agglomerative clustering.
    Returns list of (member_indices, diameter). *)
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

(** Max EV error for a clustering, measured against tree EVs. *)
let max_ev_error_from_evs (evs : float array) clusters =
  List.fold clusters ~init:0.0 ~f:(fun acc (member_indices, _diam) ->
    let member_evs = List.map member_indices ~f:(fun i -> evs.(i)) in
    let mean_ev =
      let sum = List.fold member_evs ~init:0.0 ~f:( +. ) in
      sum /. Float.of_int (List.length member_evs)
    in
    let cluster_err = List.fold member_evs ~init:0.0 ~f:(fun acc ev ->
      Float.max acc (Float.abs (ev -. mean_ev)))
    in
    Float.max acc cluster_err)

(** Find epsilon that produces closest to [target_k] clusters. *)
let _find_eps_for_k ~target_k dist_matrix max_dist n =
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

(* ------------------------------------------------------------------ *)
(* Self-play engine                                                    *)
(* ------------------------------------------------------------------ *)

type play_state = {
  to_act : int;
  num_raises : int;
  bet_outstanding : bool;
  first_checked : bool;
  p1_invested : int;
  p2_invested : int;
  round_idx : int;
}

let bet_size_for_round (config : Limit_holdem.config) round_idx =
  match round_idx with
  | 0 | 1 -> config.small_bet
  | _ -> config.big_bet

let sample_action (probs : float array) ~(n_actions : int) : int =
  let r = Random.float 1.0 in
  let cumulative = ref 0.0 in
  let chosen = ref (n_actions - 1) in
  let found = ref false in
  for i = 0 to n_actions - 1 do
    match !found with
    | true -> ()
    | false ->
      cumulative := !cumulative +. probs.(i);
      match Float.( >= ) !cumulative r with
      | true -> chosen := i; found := true
      | false -> ()
  done;
  !chosen

(** Play a single hand between two bots (possibly with different
    strategies and abstractions).  Returns P0's profit. *)
let play_hand
    ~(config : Limit_holdem.config)
    ~(p0_strat : Cfr_abstract.strategy)
    ~(p1_strat : Cfr_abstract.strategy)
    ~(p0_abs : Abstraction.abstraction_partial)
    ~(p1_abs : Abstraction.abstraction_partial)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
  : float =
  let p1_buckets =
    Cfr_abstract.precompute_buckets_equity
      ~abstraction:p0_abs ~hole_cards:p1_cards ~board
  in
  let p2_buckets =
    Cfr_abstract.precompute_buckets_equity
      ~abstraction:p1_abs ~hole_cards:p2_cards ~board
  in
  let history = Buffer.create 32 in

  let rec play_round (state : play_state) : float =
    let player = state.to_act in
    let bet_sz = bet_size_for_round config state.round_idx in
    let buckets =
      match player with
      | 0 -> p1_buckets
      | _ -> p2_buckets
    in
    let strat_table =
      match player with
      | 0 -> p0_strat
      | _ -> p1_strat
    in
    let key = Cfr_abstract.make_info_key ~buckets
        ~round_idx:state.round_idx
        ~history:(Buffer.contents history) in

    match state.bet_outstanding with
    | true ->
      let can_raise = state.num_raises < config.max_raises in
      let num_actions = match can_raise with true -> 3 | false -> 2 in
      let probs =
        match Hashtbl.find strat_table key with
        | Some p ->
          (match Array.length p = num_actions with
           | true -> p
           | false ->
             Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
        | None ->
          Array.create ~len:num_actions (1.0 /. Float.of_int num_actions)
      in
      let action_idx = sample_action probs ~n_actions:num_actions in
      (match action_idx with
       | 0 ->
         Buffer.add_char history 'f';
         let pot = state.p1_invested + state.p2_invested in
         let winner = 1 - player in
         (match winner with
          | 0 -> Float.of_int (pot / 2)
          | _ -> Float.of_int (-(pot / 2)))
       | 1 ->
         Buffer.add_char history 'c';
         let call_state = {
           state with
           bet_outstanding = false;
           p1_invested =
             (match player with
              | 0 -> state.p1_invested + bet_sz
              | _ -> state.p1_invested);
           p2_invested =
             (match player with
              | 0 -> state.p2_invested
              | _ -> state.p2_invested + bet_sz);
         } in
         advance_round call_state
       | _ ->
         Buffer.add_char history 'r';
         let raise_state = {
           state with
           to_act = 1 - player;
           num_raises = state.num_raises + 1;
           bet_outstanding = true;
           p1_invested =
             (match player with
              | 0 -> state.p1_invested + 2 * bet_sz
              | _ -> state.p1_invested);
           p2_invested =
             (match player with
              | 0 -> state.p2_invested
              | _ -> state.p2_invested + 2 * bet_sz);
         } in
         play_round raise_state)

    | false ->
      let can_bet = state.num_raises < config.max_raises in
      let num_actions = match can_bet with true -> 2 | false -> 1 in
      let probs =
        match Hashtbl.find strat_table key with
        | Some p ->
          (match Array.length p = num_actions with
           | true -> p
           | false ->
             Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
        | None ->
          Array.create ~len:num_actions (1.0 /. Float.of_int num_actions)
      in
      let action_idx = sample_action probs ~n_actions:num_actions in
      (match action_idx with
       | 0 ->
         Buffer.add_char history 'k';
         (match state.first_checked with
          | true -> advance_round state
          | false ->
            let check_state = {
              state with
              to_act = 1 - player;
              first_checked = true;
            } in
            play_round check_state)
       | _ ->
         Buffer.add_char history 'b';
         let bet_state = {
           state with
           to_act = 1 - player;
           num_raises = state.num_raises + 1;
           bet_outstanding = true;
           first_checked = false;
           p1_invested =
             (match player with
              | 0 -> state.p1_invested + bet_sz
              | _ -> state.p1_invested);
           p2_invested =
             (match player with
              | 0 -> state.p2_invested
              | _ -> state.p2_invested + bet_sz);
         } in
         play_round bet_state)

  and advance_round (state : play_state) : float =
    let next_round = state.round_idx + 1 in
    match next_round >= 4 with
    | true ->
      let pot = state.p1_invested + state.p2_invested in
      let (p1a, p1b) = p1_cards in
      let (p2a, p2b) = p2_cards in
      let hand1 = [ p1a; p1b ] @ board in
      let hand2 = [ p2a; p2b ] @ board in
      let cmp = Hand_eval7.compare_hands7 hand1 hand2 in
      (match cmp > 0 with
       | true -> Float.of_int (pot / 2)
       | false ->
         match cmp < 0 with
         | true -> Float.of_int (-(pot / 2))
         | false -> 0.0)
    | false ->
      Buffer.add_char history '/';
      let new_state = {
        state with
        to_act = 0;
        num_raises = 0;
        bet_outstanding = false;
        first_checked = false;
        round_idx = next_round;
      } in
      play_round new_state
  in

  let initial_state = {
    to_act = 0;
    num_raises = 1;
    bet_outstanding = true;
    first_checked = false;
    p1_invested = config.small_blind;
    p2_invested = config.big_blind;
    round_idx = 0;
  } in
  play_round initial_state

(* ------------------------------------------------------------------ *)
(* Main experiment                                                     *)
(* ------------------------------------------------------------------ *)

let () =
  let n_hands = ref 50 in
  let mccfr_iters = ref 50_000 in
  let play_hands = ref 10_000 in
  let n_buckets = ref 10 in
  let max_opponents = ref 15 in
  let max_board_samples = ref 10 in
  let eq_mc_samples = ref 2_000 in

  let args = [
    ("--n-hands", Arg.Set_int n_hands,
     "N  Number of canonical hands to sample (default: 50)");
    ("--mccfr-iters", Arg.Set_int mccfr_iters,
     "N  MCCFR training iterations per bot (default: 50000)");
    ("--play-hands", Arg.Set_int play_hands,
     "N  Number of self-play hands (default: 10000)");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Number of abstraction buckets (default: 10)");
    ("--max-opponents", Arg.Set_int max_opponents,
     "N  Max opponents per IS tree (default: 30)");
    ("--max-board-samples", Arg.Set_int max_board_samples,
     "N  Max board completions per IS tree (default: 10)");
    ("--eq-mc-samples", Arg.Set_int eq_mc_samples,
     "N  MC samples for preflop equity (default: 2000)");
  ] in
  Arg.parse args (fun _ -> ()) "holdem_compare.exe [options]";

  let config = Limit_holdem.standard_config in
  let t_start = Core_unix.gettimeofday () in

  printf "================================================================\n%!";
  printf "  RBM vs EMD on Full Limit Hold'em (52-card deck)\n%!";
  printf "================================================================\n\n%!";
  printf "Game: 2-player heads-up Limit Hold'em\n%!";
  printf "  SB=%d BB=%d small_bet=%d big_bet=%d max_raises=%d\n%!"
    config.small_blind config.big_blind config.small_bet config.big_bet
    config.max_raises;
  printf "Params: %d canonical hands, %d MCCFR iters, %d self-play hands\n%!"
    !n_hands !mccfr_iters !play_hands;
  printf "  IS trees: max_opponents=%d, max_board_samples=%d\n%!"
    !max_opponents !max_board_samples;
  printf "  Buckets: %d\n\n%!" !n_buckets;

  (* ================================================================ *)
  (* PART 1: Preflop Abstraction Quality                              *)
  (* ================================================================ *)
  printf "================================================================\n%!";
  printf "  PART 1: Preflop Abstraction Quality\n%!";
  printf "================================================================\n\n%!";

  (* Step 1a: Compute preflop equities, then sample canonical hands *)
  printf "[1a] Computing preflop equities for 169 canonical hands...\n%!";
  let (preflop_eq, pf_eq_time) = time (fun () ->
    fast_preflop_equities ~n_samples:!eq_mc_samples)
  in
  printf "  Preflop equities computed in %.2fs (%d MC samples)\n%!"
    pf_eq_time !eq_mc_samples;
  let (sampled_hands, eq_time) = time (fun () ->
    sample_canonical_hands ~n:!n_hands ~preflop_eq)
  in
  let n = Array.length sampled_hands in
  printf "  Selected %d hands (stride-sampled by equity) in %.2fs\n%!" n eq_time;
  printf "  Equity range: %.3f .. %.3f\n%!"
    (snd sampled_hands.(0))
    (snd sampled_hands.(n - 1));

  (* Show selected hands *)
  printf "\n  Sample of selected hands:\n%!";
  printf "  %-6s %-6s\n%!" "Hand" "Equity";
  Array.iteri sampled_hands ~f:(fun i (h, eq) ->
    match i < 10 || i >= n - 5 with
    | true -> printf "  %-6s %.3f\n%!" h.Equity.name eq
    | false ->
      match i = 10 with
      | true -> printf "  ... (%d more)\n%!" (n - 15)
      | false -> ());
  printf "\n%!";

  (* Step 1b: Build showdown distribution trees for preflop hands.
     Each tree has [n_board_samples] board-completion children, each with
     [n_opps_per_board] showdown-outcome leaves (+1/-1/0).  This is
     compact enough for fast pairwise RBM distance while capturing the
     distribution of outcomes that distinguishes strategic situations. *)
  let n_board_samples_tree = !max_board_samples in
  let n_opps_per_board = !max_opponents in
  printf "[1b] Building showdown distribution trees for %d hands...\n%!" n;
  printf "  (%d board samples x %d opponents = %d leaves/tree)\n%!"
    n_board_samples_tree n_opps_per_board
    (n_board_samples_tree * n_opps_per_board);
  let (is_trees, tree_time) = time (fun () ->
    Array.map sampled_hands ~f:(fun (h, _eq) ->
      let hole_cards = concrete_hole_cards h in
      let (h1, h2) = hole_cards in
      let dealt = [ h1; h2 ] in
      let remaining =
        List.filter Card.full_deck ~f:(fun c ->
          not (List.exists dealt ~f:(fun cc -> Card.equal c cc)))
      in
      let rem_arr = Array.of_list remaining in
      let n_rem = Array.length rem_arr in
      let board_children =
        List.init n_board_samples_tree ~f:(fun _ ->
          (* Shuffle remaining, take first 5 as board *)
          for i = 0 to Int.min 6 (n_rem - 1) do
            let j = i + Random.int (n_rem - i) in
            let tmp = rem_arr.(i) in
            rem_arr.(i) <- rem_arr.(j);
            rem_arr.(j) <- tmp
          done;
          let board = [
            rem_arr.(0); rem_arr.(1); rem_arr.(2);
            rem_arr.(3); rem_arr.(4)
          ] in
          (* Sample opponents from remaining after board *)
          let opp_start = 5 in
          let n_opp_avail = (n_rem - opp_start) / 2 in
          let n_opps = Int.min n_opps_per_board n_opp_avail in
          (* Partial shuffle for opponents *)
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
            ~label:(Rhode_island.Node_label.Chance
                      { description = "board" })
            ~children:opp_leaves)
      in
      Tree.node
        ~label:(Rhode_island.Node_label.Chance {
          description = sprintf "p1=%s%s preflop"
            (Card.to_string h1) (Card.to_string h2)
        })
        ~children:board_children))
  in
  printf "  Built %d distribution trees in %.2fs\n%!" n tree_time;
  let sample_tree = is_trees.(0) in
  printf "  Sample tree: %d nodes, %d leaves, depth %d\n%!"
    (Tree.size sample_tree) (Tree.num_leaves sample_tree)
    (Tree.depth sample_tree);
  let is_tree_list = Array.to_list is_trees in

  (* Precompute EVs for display and error measurement *)
  let tree_evs = Array.map is_trees ~f:Tree.ev in

  (* Step 1c: RBM pairwise distance matrix *)
  printf "\n[1c] Computing RBM pairwise distances (%d pairs, parallel)...\n%!"
    (n * (n - 1) / 2);
  let ((rbm_matrix, rbm_computed, rbm_skipped), rbm_time) = time (fun () ->
    Parallel.precompute_distances_parallel_pruned
      ~threshold:5.0 is_tree_list)
  in
  printf "  RBM matrix: %dx%d in %.2fs (computed=%d, ev_pruned=%d)\n%!"
    n n rbm_time rbm_computed rbm_skipped;

  (* Step 1d: EMD pairwise distance matrix *)
  printf "\n[1d] Computing EMD equity distributions for %d hands...\n%!" n;
  let n_bins = 20 in
  let n_board_samples = 500 in
  let (emd_histograms, emd_hist_time) = time (fun () ->
    Array.map sampled_hands ~f:(fun (h, _eq) ->
      preflop_equity_distribution ~n_bins ~n_board_samples h))
  in
  printf "  Histograms computed in %.2fs (%d bins, %d board samples each)\n%!"
    emd_hist_time n_bins n_board_samples;

  let (emd_matrix, emd_time) = time (fun () ->
    let m = Array.init n ~f:(fun i ->
      Array.init n ~f:(fun j ->
        match i <= j with
        | true ->
          Abstraction.emd_histograms emd_histograms.(i) emd_histograms.(j)
        | false -> 0.0))
    in
    for i = 0 to n - 1 do
      for j = 0 to i - 1 do
        m.(i).(j) <- m.(j).(i)
      done
    done;
    m)
  in
  printf "  EMD matrix: %dx%d in %.3fs\n%!" n n emd_time;

  (* Step 1e: Scalar EV distance matrix *)
  let equities_arr =
    Array.map sampled_hands ~f:(fun (_h, eq) -> eq)
  in
  let (ev_matrix, ev_time) = time (fun () ->
    let m = Array.init n ~f:(fun i ->
      Array.init n ~f:(fun j ->
        Float.abs (equities_arr.(i) -. equities_arr.(j))))
    in
    m)
  in
  printf "  EV matrix: %dx%d in %.3fs\n\n%!" n n ev_time;

  (* Step 1f: Find max distances for sweep *)
  let max_rbm = ref 0.0 in
  let max_emd = ref 0.0 in
  let max_ev = ref 0.0 in
  for i = 0 to n - 1 do
    for j = i + 1 to n - 1 do
      (match Float.is_finite rbm_matrix.(i).(j) with
       | true -> max_rbm := Float.max !max_rbm rbm_matrix.(i).(j)
       | false -> ());
      max_emd := Float.max !max_emd emd_matrix.(i).(j);
      max_ev := Float.max !max_ev ev_matrix.(i).(j)
    done
  done;

  (* Step 1g: Sweep epsilon for all methods, collect (k, err) *)
  printf "[1f] Clustering sweep (40 epsilon steps per method)...\n%!";
  let n_steps = 40 in

  let sweep_with_matrix dist_matrix max_dist =
    let results = ref [] in
    for step = 0 to n_steps do
      let frac = Float.of_int step /. Float.of_int n_steps in
      let eps = frac *. max_dist *. 1.1 in
      let clusters = cluster_by_distance_matrix ~epsilon:eps dist_matrix n in
      let k = List.length clusters in
      let err = max_ev_error_from_evs tree_evs clusters in
      results := (k, err) :: !results
    done;
    !results
  in

  let (rbm_results, rbm_sweep_t) = time (fun () ->
    sweep_with_matrix rbm_matrix !max_rbm)
  in
  let (emd_results, emd_sweep_t) = time (fun () ->
    sweep_with_matrix emd_matrix !max_emd)
  in
  let (ev_results, ev_sweep_t) = time (fun () ->
    sweep_with_matrix ev_matrix !max_ev)
  in
  printf "  Sweep times: RBM=%.3fs EMD=%.3fs EV=%.3fs\n\n%!"
    rbm_sweep_t emd_sweep_t ev_sweep_t;

  (* Best error at each k *)
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

  (* Target k values *)
  let target_ks =
    [ 25; 15; 10; 5; 3 ]
    |> List.filter ~f:(fun k -> k <= n && k >= 1)
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

  printf "=== Preflop Abstraction Quality ===\n\n%!";
  printf "  All methods clustered by their own metric, error measured as\n%!";
  printf "  max |tree_EV - cluster_mean_EV| (the game-theoretic ground truth).\n\n%!";
  printf "  %-5s  %-10s  %-10s  %-10s  %-8s\n%!"
    "k" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 53 '-');

  let rbm_wins = ref 0 in
  let emd_wins = ref 0 in
  let ev_wins = ref 0 in
  let ties = ref 0 in

  List.iter target_ks ~f:(fun target_k ->
    let format_entry entry =
      match entry with
      | None -> ("N/A", Float.infinity)
      | Some (k, err) ->
        match k = target_k with
        | true -> (sprintf "%.4f" err, err)
        | false -> (sprintf "%.4f[%d]" err k, err)
    in

    let rbm_str, rbm_err = format_entry (find_closest_k rbm_by_k target_k) in
    let emd_str, emd_err = format_entry (find_closest_k emd_by_k target_k) in
    let ev_str, ev_err = format_entry (find_closest_k ev_by_k target_k) in

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
          (* Track wins *)
          (match String.equal best_name "RBM" with
           | true -> Int.incr rbm_wins
           | false ->
             match String.equal best_name "EMD" with
             | true -> Int.incr emd_wins
             | false ->
               match String.equal best_name "EV" with
               | true -> Int.incr ev_wins
               | false -> Int.incr ties);
          best_name
    in
    printf "  %-5d  %-10s  %-10s  %-10s  %-8s\n%!"
      target_k rbm_str emd_str ev_str winner);

  printf "\n  Abstraction quality wins: RBM=%d EMD=%d EV=%d Tie=%d\n\n%!"
    !rbm_wins !emd_wins !ev_wins !ties;

  (* ================================================================ *)
  (* PART 2: MCCFR Head-to-Head                                      *)
  (* ================================================================ *)
  printf "================================================================\n%!";
  printf "  PART 2: MCCFR Head-to-Head\n%!";
  printf "================================================================\n\n%!";

  (* Build abstractions *)
  printf "[2a] Building %d-bucket preflop abstractions...\n%!" !n_buckets;
  let (rbm_abs, rbm_abs_time) = time (fun () ->
    (* For RBM-based preflop abstraction: build IS trees for all 169 hands,
       cluster by RBM distance, assign buckets.
       But this is expensive, so we use a fast approach: build IS trees for
       a subset, compute distances, k-means partition. *)

    (* Use all 169 canonical hands but with very small IS trees *)
    let all_equities = fast_preflop_equities ~n_samples:!eq_mc_samples in
    (* Build small IS trees for 169 hands *)
    let small_trees = Array.map (Array.of_list Equity.all_canonical_hands)
        ~f:(fun (h : Equity.canonical_hand) ->
          let hole_cards = concrete_hole_cards h in
          Limit_holdem.information_set_tree
            ~max_opponents:10 ~max_board_samples:5
            ~config ~player:0 ~hole_cards ~board_visible:[]
            ~round_idx:0 ~pot_so_far:3 ())
    in
    let small_evs = Array.map small_trees ~f:Tree.ev in
    (* Use IS tree EVs (game-theoretic values) for bucketing instead of
       raw equity.  This captures the strategic value better. *)
    let assignments, centroids =
      Abstraction.quantile_bucketing ~n_buckets:!n_buckets small_evs
    in
    ignore all_equities;
    ({ Abstraction.street = Preflop
     ; n_buckets = !n_buckets
     ; assignments
     ; centroids
     } : Abstraction.abstraction_partial))
  in
  printf "  RBM abstraction built in %.2fs\n%!" rbm_abs_time;

  let (emd_abs, emd_abs_time) = time (fun () ->
    fast_preflop_abstraction ~n_buckets:!n_buckets ~n_samples:!eq_mc_samples)
  in
  printf "  EMD abstraction built in %.2fs\n\n%!" emd_abs_time;

  (* Show bucket assignments for key hands *)
  printf "  Bucket assignments (RBM vs EMD):\n%!";
  printf "  %-6s  %-5s  %-5s\n%!" "Hand" "RBM" "EMD";
  let key_hands = [
    ("AA", Card.Rank.Ace, Card.Rank.Ace, false);
    ("KK", King, King, false);
    ("AKs", Ace, King, true);
    ("AKo", Ace, King, false);
    ("QJs", Queen, Jack, true);
    ("TT", Ten, Ten, false);
    ("55", Five, Five, false);
    ("72o", Seven, Two, false);
    ("32o", Three, Two, false);
  ] in
  List.iter key_hands ~f:(fun (name, r1, r2, suited) ->
    let hole_cards =
      match Card.Rank.equal r1 r2 with
      | true ->
        ({ Card.rank = r1; suit = Card.Suit.Hearts },
         { Card.rank = r2; suit = Card.Suit.Spades })
      | false ->
        match suited with
        | true ->
          ({ Card.rank = r1; suit = Card.Suit.Hearts },
           { Card.rank = r2; suit = Card.Suit.Hearts })
        | false ->
          ({ Card.rank = r1; suit = Card.Suit.Hearts },
           { Card.rank = r2; suit = Card.Suit.Diamonds })
    in
    let rbm_b = Abstraction.get_bucket rbm_abs ~hole_cards in
    let emd_b = Abstraction.get_bucket emd_abs ~hole_cards in
    printf "  %-6s  %-5d  %-5d\n%!" name rbm_b emd_b);
  printf "\n%!";

  (* Train MCCFR *)
  printf "[2b] Training RBM bot (%d iters, %d buckets)...\n%!" !mccfr_iters !n_buckets;
  let ((rbm_p0, rbm_p1), rbm_train_time) = time (fun () ->
    Cfr_abstract.train_mccfr ~config ~abstraction:rbm_abs
      ~iterations:!mccfr_iters ~report_every:10_000
      ~bucket_method:Equity_based ())
  in
  printf "  RBM training: %.2fs, P0=%d P1=%d info sets\n%!"
    rbm_train_time (Hashtbl.length rbm_p0) (Hashtbl.length rbm_p1);

  printf "\n[2c] Training EMD bot (%d iters, %d buckets)...\n%!" !mccfr_iters !n_buckets;
  let ((emd_p0, emd_p1), emd_train_time) = time (fun () ->
    Cfr_abstract.train_mccfr ~config ~abstraction:emd_abs
      ~iterations:!mccfr_iters ~report_every:10_000
      ~bucket_method:Equity_based ())
  in
  printf "  EMD training: %.2fs, P0=%d P1=%d info sets\n\n%!"
    emd_train_time (Hashtbl.length emd_p0) (Hashtbl.length emd_p1);

  (* ================================================================ *)
  (* Head-to-head: RBM bot as P0 vs EMD bot as P1                    *)
  (* ================================================================ *)
  printf "[2d] Self-play: RBM bot vs EMD bot (%d hands)...\n%!" !play_hands;

  let rbm_as_p0_profit = ref 0.0 in
  let rbm_as_p1_profit = ref 0.0 in

  let ((), play_time) = time (fun () ->
    for _ = 1 to !play_hands do
      let (p1_cards, p2_cards, board) = sample_deal () in
      (* RBM as P0 (SB), EMD as P1 (BB) *)
      let profit_1 = play_hand ~config
          ~p0_strat:rbm_p0 ~p1_strat:emd_p1
          ~p0_abs:rbm_abs ~p1_abs:emd_abs
          ~p1_cards ~p2_cards ~board
      in
      rbm_as_p0_profit := !rbm_as_p0_profit +. profit_1;
      (* EMD as P0 (SB), RBM as P1 (BB) -- swap positions *)
      let profit_2 = play_hand ~config
          ~p0_strat:emd_p0 ~p1_strat:rbm_p1
          ~p0_abs:emd_abs ~p1_abs:rbm_abs
          ~p1_cards ~p2_cards ~board
      in
      (* profit_2 is from EMD-as-P0's perspective, so RBM's is negative *)
      rbm_as_p1_profit := !rbm_as_p1_profit -. profit_2
    done)
  in

  let total_rbm_profit =
    !rbm_as_p0_profit +. !rbm_as_p1_profit
  in
  let total_hands = 2 * !play_hands in
  let avg_bb_per_hand =
    total_rbm_profit /. Float.of_int total_hands
      /. Float.of_int config.big_blind
  in

  printf "  Self-play completed in %.2fs\n\n%!" play_time;

  (* ================================================================ *)
  (* FINAL REPORT                                                     *)
  (* ================================================================ *)
  let t_end = Core_unix.gettimeofday () in
  let total_time = t_end -. t_start in

  printf "================================================================\n%!";
  printf "  FINAL REPORT: RBM vs EMD on Full Limit Hold'em\n%!";
  printf "================================================================\n\n%!";

  printf "Preflop Abstraction Quality (max EV error, lower is better):\n\n%!";
  printf "  %-5s  %-10s  %-10s  %-10s  %-8s\n%!"
    "k" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 53 '-');

  List.iter target_ks ~f:(fun target_k ->
    let format_entry entry =
      match entry with
      | None -> "N/A"
      | Some (k, err) ->
        match k = target_k with
        | true -> sprintf "%.4f" err
        | false -> sprintf "%.4f[%d]" err k
    in
    let rbm_str = format_entry (find_closest_k rbm_by_k target_k) in
    let emd_str = format_entry (find_closest_k emd_by_k target_k) in
    let ev_str = format_entry (find_closest_k ev_by_k target_k) in

    let get_err entry = Option.value_map entry ~default:Float.infinity ~f:snd in
    let rbm_err = get_err (find_closest_k rbm_by_k target_k) in
    let emd_err = get_err (find_closest_k emd_by_k target_k) in
    let ev_err = get_err (find_closest_k ev_by_k target_k) in
    let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
    let winner =
      let tol = 0.0001 in
      match Float.( < ) (Float.abs (rbm_err -. min_err)) tol with
      | true -> "RBM"
      | false ->
        match Float.( < ) (Float.abs (emd_err -. min_err)) tol with
        | true -> "EMD"
        | false -> "EV"
    in
    printf "  %-5d  %-10s  %-10s  %-10s  %-8s\n%!"
      target_k rbm_str emd_str ev_str winner);

  printf "\nMCCFR Head-to-Head (%d hands, position-alternated):\n\n%!"
    total_hands;
  printf "  RBM bot (%d buckets, %dK iter) vs EMD bot (%d buckets, %dK iter)\n%!"
    !n_buckets (!mccfr_iters / 1000) !n_buckets (!mccfr_iters / 1000);
  printf "  RBM as P0 profit:  %+.1f (%.4f bb/hand)\n%!"
    !rbm_as_p0_profit
    (!rbm_as_p0_profit /. Float.of_int !play_hands
     /. Float.of_int config.big_blind);
  printf "  RBM as P1 profit:  %+.1f (%.4f bb/hand)\n%!"
    !rbm_as_p1_profit
    (!rbm_as_p1_profit /. Float.of_int !play_hands
     /. Float.of_int config.big_blind);
  printf "  RBM total profit:  %+.1f\n%!" total_rbm_profit;
  printf "  RBM avg profit:    %+.4f bb/hand\n%!" avg_bb_per_hand;
  let winner_str =
    match Float.( > ) avg_bb_per_hand 0.01 with
    | true -> "RBM"
    | false ->
      match Float.( < ) avg_bb_per_hand (-0.01) with
      | true -> "EMD"
      | false -> "DRAW (within noise)"
  in
  printf "  Winner:            %s\n%!" winner_str;

  printf "\nTiming:\n%!";
  printf "  IS tree construction:  %.2fs\n%!" tree_time;
  printf "  RBM distance matrix:   %.2fs\n%!" rbm_time;
  printf "  EMD distributions:     %.2fs\n%!" emd_hist_time;
  printf "  RBM MCCFR training:    %.2fs\n%!" rbm_train_time;
  printf "  EMD MCCFR training:    %.2fs\n%!" emd_train_time;
  printf "  Self-play:             %.2fs\n%!" play_time;
  printf "  Total wall time:       %.2fs\n\n%!" total_time;

  printf "================================================================\n%!";
  printf "  This is the game Bowling et al. (2015) solved.\n%!";
  printf "  RBM captures game-tree structure; EMD sees only equity.\n%!";
  printf "================================================================\n%!"
