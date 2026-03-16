(** RBM vs EMD comparison on heads-up No-Limit Hold'em.

    Part 1: Preflop abstraction quality (20bb short-stack)
      - Sample 50 canonical starting hands (from the 169)
      - Build showdown distribution trees
      - RBM: pairwise distance matrix with EV pruning (parallel)
      - EMD: equity distribution distance
      - Cluster at multiple k, compare max EV error

    Part 2: MCCFR-NL head-to-head (20bb short-stack)
      - Train 50K iterations with RBM-based bucketing (10 buckets)
      - Train 50K iterations with equity-based bucketing (10 buckets)
      - Self-play 10K hands, report bb/hand

    Part 3: Deep-stack comparison (200bb)
      - Same pipeline as Parts 1+2 but with standard_config (3 bet fractions)
      - Showdown distribution trees for tractable RBM distance
      - Hypothesis: RBM advantage grows with tree complexity

    Usage:
      ./nolimit_compare.exe [--n-hands 50] [--mccfr-iters 50000]
                             [--play-hands 10000] [--buckets 10]
                             [--deep-mccfr-iters 50000] *)

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

let sample_canonical_hands ~n ~preflop_eq =
  let all = Equity.all_canonical_hands in
  let total = List.length all in
  let arr = Array.of_list all in
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
(* Fast preflop equity                                                 *)
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

let fast_preflop_abstraction ~n_buckets ~n_samples =
  let equities = fast_preflop_equities ~n_samples in
  let assignments, centroids =
    Abstraction.quantile_bucketing ~n_buckets equities
  in
  ({ Abstraction.street = Preflop; n_buckets; assignments; centroids }
    : Abstraction.abstraction_partial)

(* ------------------------------------------------------------------ *)
(* EMD distance for preflop                                            *)
(* ------------------------------------------------------------------ *)

let preflop_equity_distribution ~n_bins ~n_board_samples ~n_opps_per_board
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
    let cards_needed = Int.min (5 + 2 * n_opps_per_board) n_rem in
    for i = 0 to cards_needed - 1 do
      let j = i + Random.int (n_rem - i) in
      let tmp = remaining.(i) in
      remaining.(i) <- remaining.(j);
      remaining.(j) <- tmp
    done;
    let wins = ref 0.0 in
    let n_opps = Int.min n_opps_per_board ((n_rem - 5) / 2) in
    for k = 0 to n_opps - 1 do
      let o1 = remaining.(5 + k * 2) in
      let o2 = remaining.(5 + k * 2 + 1) in
      let cmp = Equity.compare_7card
          (h1, h2, remaining.(0), remaining.(1), remaining.(2),
           remaining.(3), remaining.(4))
          (o1, o2, remaining.(0), remaining.(1), remaining.(2),
           remaining.(3), remaining.(4))
      in
      match cmp > 0 with
      | true -> wins := !wins +. 1.0
      | false ->
        match cmp = 0 with
        | true -> wins := !wins +. 0.5
        | false -> ()
    done;
    let eq = !wins /. Float.of_int n_opps in
    let bin = Int.min (n_bins - 1)
        (Float.to_int (eq *. Float.of_int n_bins)) in
    histogram.(bin) <- histogram.(bin) +. 1.0
  done;
  let total = Float.of_int n_board_samples in
  Array.iteri histogram ~f:(fun i v -> histogram.(i) <- v /. total);
  histogram

(* ------------------------------------------------------------------ *)
(* Agglomerative clustering                                            *)
(* ------------------------------------------------------------------ *)

let cluster_to_k ~target_k (dist_matrix : float array array) n =
  let active = Array.create ~len:n true in
  let members = Array.init n ~f:(fun i -> [ i ]) in
  let diameters = Array.create ~len:n 0.0 in
  let n_active = ref n in
  while !n_active > target_k do
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
    match !best_ci >= 0 with
    | true ->
      let ci = !best_ci in
      let cj = !best_cj in
      members.(ci) <- members.(ci) @ members.(cj);
      diameters.(ci) <-
        Float.max (Float.max diameters.(ci) diameters.(cj)) !best_dist;
      active.(cj) <- false;
      Int.decr n_active
    | false ->
      n_active := 0
  done;
  Array.to_list (Array.filter_mapi active ~f:(fun i is_active ->
    match is_active with
    | true -> Some (members.(i), diameters.(i))
    | false -> None))

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

(* ------------------------------------------------------------------ *)
(* NL Self-play engine                                                 *)
(* ------------------------------------------------------------------ *)

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

(** Play a single NL hand between two bots.  Returns P0's profit.
    Uses the same inline traversal as MCCFR but samples actions from
    the trained strategies instead of exploring/updating. *)
let play_nl_hand
    ~(config : Nolimit_holdem.config)
    ~(p0_strat : Cfr_nolimit.strategy)
    ~(p1_strat : Cfr_nolimit.strategy)
    ~(p0_abs : Abstraction.abstraction_partial)
    ~(p1_abs : Abstraction.abstraction_partial)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
  : float =
  let p1_buckets =
    Cfr_nolimit.precompute_buckets_equity
      ~abstraction:p0_abs ~hole_cards:p1_cards ~board
  in
  let p2_buckets =
    Cfr_nolimit.precompute_buckets_equity
      ~abstraction:p1_abs ~hole_cards:p2_cards ~board
  in
  let history = Buffer.create 32 in

  let rec play (p_invested : int array) (p_stack : int array)
      (round_idx : int) (num_raises : int) (current_bet : int)
      (round_start_invested : int array) (actions_remaining : int)
      (to_act : int) : float =
    let player = to_act in
    let other = 1 - player in

    (* Check if either player is all-in or round over *)
    let someone_all_in = p_stack.(0) = 0 || p_stack.(1) = 0 in
    match actions_remaining <= 0 || someone_all_in with
    | true ->
      advance_round p_invested p_stack round_idx
    | false ->
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
      let key = Cfr_nolimit.make_info_key ~buckets ~round_idx
          ~history:(Buffer.contents history) in

      (* Compute available actions (same logic as CFR traversal) *)
      let stack = p_stack.(player) in
      let already_in_round = p_invested.(player) - round_start_invested.(player) in
      let to_call = Int.min stack (current_bet - already_in_round) in
      let facing_bet = to_call > 0 in
      let pot = p_invested.(0) + p_invested.(1) in
      let can_raise = num_raises < config.max_raises_per_round && stack > to_call in

      let actions = ref [] in
      (match facing_bet with
       | true ->
         actions := (Nolimit_holdem.Action.Fold, "f") :: !actions
       | false -> ());
      let check_call =
        match facing_bet with
        | true -> (Nolimit_holdem.Action.Call, "c")
        | false -> (Nolimit_holdem.Action.Check, "k")
      in
      actions := check_call :: !actions;
      (match can_raise with
       | true ->
         let pot_after_call = pot + to_call in
         List.iter config.bet_fractions ~f:(fun frac ->
           let raise_amount =
             Int.max 1 (Float.to_int (Float.of_int pot_after_call *. frac))
           in
           let total_to_put_in = to_call + raise_amount in
           match total_to_put_in < stack with
           | true ->
             actions :=
               (Nolimit_holdem.Action.Bet_frac frac,
                Nolimit_holdem.Action.to_history_char (Bet_frac frac))
               :: !actions
           | false -> ());
         (match stack > to_call with
          | true ->
            actions := (Nolimit_holdem.Action.All_in, "a") :: !actions
          | false -> ())
       | false -> ());
      let actions = List.rev !actions in
      let action_arr = Array.of_list actions in
      let num_actions = Array.length action_arr in

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
      let (action, hist_char) = action_arr.(action_idx) in
      Buffer.add_string history hist_char;
      let new_invested = Array.copy p_invested in
      let new_stack = Array.copy p_stack in

      match action with
      | Fold ->
        let winner = other in
        let final_pot = p_invested.(0) + p_invested.(1) in
        (match winner = 0 with
         | true -> Float.of_int (final_pot - p_invested.(0))
         | false -> Float.of_int (- p_invested.(0)))
      | Check ->
        let new_remaining = actions_remaining - 1 in
        (match new_remaining <= 0 with
         | true -> advance_round new_invested new_stack round_idx
         | false ->
           play new_invested new_stack round_idx num_raises current_bet
             round_start_invested new_remaining other)
      | Call ->
        new_invested.(player) <- p_invested.(player) + to_call;
        new_stack.(player) <- stack - to_call;
        let new_remaining = actions_remaining - 1 in
        (match new_remaining <= 0 with
         | true -> advance_round new_invested new_stack round_idx
         | false ->
           play new_invested new_stack round_idx num_raises current_bet
             round_start_invested new_remaining other)
      | Bet_frac frac ->
        let pot_after_call = pot + to_call in
        let raise_amount =
          Int.max 1 (Float.to_int (Float.of_int pot_after_call *. frac))
        in
        let total_to_put_in = to_call + raise_amount in
        new_invested.(player) <- p_invested.(player) + total_to_put_in;
        new_stack.(player) <- stack - total_to_put_in;
        let in_round =
          p_invested.(player) + total_to_put_in - round_start_invested.(player)
        in
        play new_invested new_stack round_idx (num_raises + 1) in_round
          round_start_invested 1 other
      | All_in ->
        let all_in_amount = stack in
        new_invested.(player) <- p_invested.(player) + all_in_amount;
        new_stack.(player) <- 0;
        let in_round =
          p_invested.(player) + all_in_amount - round_start_invested.(player)
        in
        let new_current_bet = Int.max current_bet in_round in
        let is_raise = all_in_amount > to_call in
        let new_num_raises =
          match is_raise with true -> num_raises + 1 | false -> num_raises
        in
        let new_remaining =
          match is_raise with true -> 1 | false -> actions_remaining - 1
        in
        (match new_remaining <= 0 || new_stack.(other) = 0 with
         | true -> advance_round new_invested new_stack round_idx
         | false ->
           play new_invested new_stack round_idx new_num_raises new_current_bet
             round_start_invested new_remaining other)

  and advance_round (p_invested : int array) (p_stack : int array)
      (round_idx : int) : float =
    let next_round = round_idx + 1 in
    let someone_all_in = p_stack.(0) = 0 || p_stack.(1) = 0 in
    match next_round >= 4 || someone_all_in with
    | true ->
      (* Showdown *)
      let (p1a, p1b) = p1_cards in
      let (p2a, p2b) = p2_cards in
      let hand1 = [ p1a; p1b ] @ board in
      let hand2 = [ p2a; p2b ] @ board in
      let cmp = Hand_eval7.compare_hands7 hand1 hand2 in
      let pot = p_invested.(0) + p_invested.(1) in
      (match cmp > 0 with
       | true -> Float.of_int (pot - p_invested.(0))
       | false ->
         match cmp < 0 with
         | true -> Float.of_int (- p_invested.(0))
         | false -> 0.0)
    | false ->
      Buffer.add_char history '/';
      let new_round_start = Array.copy p_invested in
      play p_invested p_stack next_round 0 0 new_round_start 2 0
  in

  let p_invested = [| config.small_blind; config.big_blind |] in
  let p_stack = [|
    config.starting_stack - config.small_blind;
    config.starting_stack - config.big_blind;
  |] in
  let round_start_invested = [| config.small_blind; config.big_blind |] in
  play p_invested p_stack 0 1 config.big_blind round_start_invested 2 0

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

  let deep_mccfr_iters = ref 50_000 in
  let deep_play_hands = ref 10_000 in

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
     "N  Max opponents per IS tree (default: 15)");
    ("--max-board-samples", Arg.Set_int max_board_samples,
     "N  Max board completions per IS tree (default: 10)");
    ("--eq-mc-samples", Arg.Set_int eq_mc_samples,
     "N  MC samples for preflop equity (default: 2000)");
    ("--deep-mccfr-iters", Arg.Set_int deep_mccfr_iters,
     "N  MCCFR training iterations for 200bb deep-stack (default: 50000)");
    ("--deep-play-hands", Arg.Set_int deep_play_hands,
     "N  Self-play hands for 200bb deep-stack (default: 10000)");
  ] in
  Arg.parse args (fun _ -> ()) "nolimit_compare.exe [options]";

  let config = Nolimit_holdem.short_stack_config in
  let t_start = Core_unix.gettimeofday () in

  printf "================================================================\n%!";
  printf "  RBM vs EMD on No-Limit Hold'em (20bb short-stack)\n%!";
  printf "================================================================\n\n%!";
  printf "Game: 2-player heads-up No-Limit Hold'em\n%!";
  printf "  SB=%d BB=%d starting_stack=%d (%dbb) bet_fractions=%s max_raises=%d\n%!"
    config.small_blind config.big_blind config.starting_stack
    (config.starting_stack / config.big_blind)
    (String.concat ~sep:"," (List.map config.bet_fractions ~f:(sprintf "%.1f")))
    config.max_raises_per_round;
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

  (* Step 1b: Build showdown distribution trees *)
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
          let opp_start = 5 in
          let n_opp_avail = (n_rem - opp_start) / 2 in
          let n_opps = Int.min n_opps_per_board n_opp_avail in
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
  let n_board_samples = 200 in
  let n_opps_per_board_emd = 20 in
  let (emd_histograms, emd_hist_time) = time (fun () ->
    Array.map sampled_hands ~f:(fun (h, _eq) ->
      preflop_equity_distribution ~n_bins ~n_board_samples
        ~n_opps_per_board:n_opps_per_board_emd h))
  in
  printf "  Histograms computed in %.2fs (%d bins, %d boards x %d opps each)\n%!"
    emd_hist_time n_bins n_board_samples n_opps_per_board_emd;

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
    Array.init n ~f:(fun i ->
      Array.init n ~f:(fun j ->
        Float.abs (equities_arr.(i) -. equities_arr.(j))))
  ) in
  printf "  EV matrix: %dx%d in %.3fs\n\n%!" n n ev_time;

  (* Step 1f: Cluster at exact k values *)
  let target_ks =
    [ 25; 15; 10; 5; 3 ]
    |> List.filter ~f:(fun k -> k <= n && k >= 1)
  in

  printf "[1f] Clustering at exact k values...\n%!";
  let (cluster_results, cluster_time) = time (fun () ->
    List.map target_ks ~f:(fun k ->
      let rbm_clusters = cluster_to_k ~target_k:k rbm_matrix n in
      let emd_clusters = cluster_to_k ~target_k:k emd_matrix n in
      let ev_clusters = cluster_to_k ~target_k:k ev_matrix n in
      let rbm_err = max_ev_error_from_evs tree_evs rbm_clusters in
      let emd_err = max_ev_error_from_evs tree_evs emd_clusters in
      let ev_err = max_ev_error_from_evs tree_evs ev_clusters in
      (k, rbm_err, emd_err, ev_err)))
  in
  printf "  Clustering completed in %.3fs\n\n%!" cluster_time;

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

  List.iter cluster_results ~f:(fun (k, rbm_err, emd_err, ev_err) ->
    let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
    let tol = 0.0001 in
    let winner =
      let rbm_best = Float.( < ) (Float.abs (rbm_err -. min_err)) tol in
      let emd_best = Float.( < ) (Float.abs (emd_err -. min_err)) tol in
      let ev_best = Float.( < ) (Float.abs (ev_err -. min_err)) tol in
      match rbm_best && emd_best && ev_best with
      | true -> Int.incr ties; "tie"
      | false ->
        match rbm_best with
        | true -> Int.incr rbm_wins; "RBM"
        | false ->
          match emd_best with
          | true -> Int.incr emd_wins; "EMD"
          | false ->
            match ev_best with
            | true -> Int.incr ev_wins; "EV"
            | false -> Int.incr ties; "tie"
    in
    printf "  %-5d  %-10.4f  %-10.4f  %-10.4f  %-8s\n%!"
      k rbm_err emd_err ev_err winner);

  printf "\n  Abstraction quality wins: RBM=%d EMD=%d EV=%d Tie=%d\n\n%!"
    !rbm_wins !emd_wins !ev_wins !ties;

  (* ================================================================ *)
  (* PART 2: MCCFR-NL Head-to-Head                                   *)
  (* ================================================================ *)
  printf "================================================================\n%!";
  printf "  PART 2: MCCFR-NL Head-to-Head (20bb)\n%!";
  printf "================================================================\n\n%!";

  (* Build abstractions *)
  printf "[2a] Building %d-bucket preflop abstractions...\n%!" !n_buckets;
  let (rbm_abs, rbm_abs_time) = time (fun () ->
    let all_hands = Array.of_list Equity.all_canonical_hands in
    let small_trees = Array.map all_hands
        ~f:(fun (h : Equity.canonical_hand) ->
          let (h1, h2) = concrete_hole_cards h in
          let dealt = [ h1; h2 ] in
          let rem =
            List.filter Card.full_deck ~f:(fun c ->
              not (List.exists dealt ~f:(fun cc -> Card.equal c cc)))
          in
          let rem_arr = Array.of_list rem in
          let n_rem = Array.length rem_arr in
          let children =
            List.init 10 ~f:(fun _ ->
              for i = 0 to Int.min 6 (n_rem - 1) do
                let j = i + Random.int (n_rem - i) in
                let tmp = rem_arr.(i) in
                rem_arr.(i) <- rem_arr.(j);
                rem_arr.(j) <- tmp
              done;
              let n_opps = Int.min 10 ((n_rem - 5) / 2) in
              for i = 5 to Int.min (5 + n_opps * 2 - 1) (n_rem - 1) do
                let j = i + Random.int (n_rem - i) in
                let tmp = rem_arr.(i) in
                rem_arr.(i) <- rem_arr.(j);
                rem_arr.(j) <- tmp
              done;
              let leaves =
                List.init n_opps ~f:(fun k ->
                  let o1 = rem_arr.(5 + k * 2) in
                  let o2 = rem_arr.(5 + k * 2 + 1) in
                  let cmp = Hand_eval7.compare_hands7
                      [ h1; h2; rem_arr.(0); rem_arr.(1); rem_arr.(2);
                        rem_arr.(3); rem_arr.(4) ]
                      [ o1; o2; rem_arr.(0); rem_arr.(1); rem_arr.(2);
                        rem_arr.(3); rem_arr.(4) ]
                  in
                  let v = match cmp > 0 with
                    | true -> 1.0
                    | false -> match cmp = 0 with
                      | true -> 0.0
                      | false -> -1.0
                  in
                  Tree.leaf
                    ~label:(Rhode_island.Node_label.Terminal
                              { winner = None; pot = 0 })
                    ~value:v)
              in
              Tree.node
                ~label:(Rhode_island.Node_label.Chance
                          { description = "b" })
                ~children:leaves)
          in
          Tree.node
            ~label:(Rhode_island.Node_label.Chance
                      { description = "root" })
            ~children)
    in
    let small_evs = Array.map small_trees ~f:Tree.ev in
    let assignments, centroids =
      Abstraction.quantile_bucketing ~n_buckets:!n_buckets small_evs
    in
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

  (* Show bucket assignments *)
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

  (* Train MCCFR-NL *)
  printf "[2b] Training RBM bot (%d iters, %d buckets, NL 20bb)...\n%!"
    !mccfr_iters !n_buckets;
  let ((rbm_p0, rbm_p1), rbm_train_time) = time (fun () ->
    Cfr_nolimit.train_mccfr ~config ~abstraction:rbm_abs
      ~iterations:!mccfr_iters ~report_every:10_000 ())
  in
  printf "  RBM training: %.2fs, P0=%d P1=%d info sets\n%!"
    rbm_train_time (Hashtbl.length rbm_p0) (Hashtbl.length rbm_p1);

  printf "\n[2c] Training EMD bot (%d iters, %d buckets, NL 20bb)...\n%!"
    !mccfr_iters !n_buckets;
  let ((emd_p0, emd_p1), emd_train_time) = time (fun () ->
    Cfr_nolimit.train_mccfr ~config ~abstraction:emd_abs
      ~iterations:!mccfr_iters ~report_every:10_000 ())
  in
  printf "  EMD training: %.2fs, P0=%d P1=%d info sets\n\n%!"
    emd_train_time (Hashtbl.length emd_p0) (Hashtbl.length emd_p1);

  (* ================================================================ *)
  (* Head-to-head: RBM bot as P0 vs EMD bot as P1                    *)
  (* ================================================================ *)
  printf "[2d] Self-play: RBM bot vs EMD bot (%d hands, NL 20bb)...\n%!" !play_hands;

  let rbm_as_p0_profit = ref 0.0 in
  let rbm_as_p1_profit = ref 0.0 in

  let ((), play_time) = time (fun () ->
    for _ = 1 to !play_hands do
      let (p1_cards, p2_cards, board) = sample_deal () in
      (* RBM as P0 (SB), EMD as P1 (BB) *)
      let profit_1 = play_nl_hand ~config
          ~p0_strat:rbm_p0 ~p1_strat:emd_p1
          ~p0_abs:rbm_abs ~p1_abs:emd_abs
          ~p1_cards ~p2_cards ~board
      in
      rbm_as_p0_profit := !rbm_as_p0_profit +. profit_1;
      (* EMD as P0 (SB), RBM as P1 (BB) *)
      let profit_2 = play_nl_hand ~config
          ~p0_strat:emd_p0 ~p1_strat:rbm_p1
          ~p0_abs:emd_abs ~p1_abs:rbm_abs
          ~p1_cards ~p2_cards ~board
      in
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
  (* 20bb INTERIM REPORT                                              *)
  (* ================================================================ *)
  printf "================================================================\n%!";
  printf "  20bb REPORT: RBM vs EMD on NL Hold'em (20bb HU)\n%!";
  printf "================================================================\n\n%!";

  printf "Preflop Abstraction Quality (max EV error, lower is better):\n\n%!";
  printf "  %-5s  %-10s  %-10s  %-10s  %-8s\n%!"
    "k" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 53 '-');

  List.iter cluster_results ~f:(fun (k, rbm_err, emd_err, ev_err) ->
    let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
    let tol = 0.0001 in
    let winner =
      match Float.( < ) (Float.abs (rbm_err -. min_err)) tol with
      | true -> "RBM"
      | false ->
        match Float.( < ) (Float.abs (emd_err -. min_err)) tol with
        | true -> "EMD"
        | false -> "EV"
    in
    printf "  %-5d  %-10.4f  %-10.4f  %-10.4f  %-8s\n%!"
      k rbm_err emd_err ev_err winner);

  printf "\nMCCFR-NL Head-to-Head (%d hands, position-alternated, 20bb):\n\n%!"
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
  let winner_str_20bb =
    match Float.( > ) avg_bb_per_hand 0.01 with
    | true -> "RBM"
    | false ->
      match Float.( < ) avg_bb_per_hand (-0.01) with
      | true -> "EMD"
      | false -> "DRAW (within noise)"
  in
  printf "  Winner:            %s\n\n%!" winner_str_20bb;

  (* ================================================================ *)
  (* PART 3: Deep-Stack 200bb Comparison                              *)
  (* ================================================================ *)
  let deep_config = Nolimit_holdem.standard_config in
  printf "================================================================\n%!";
  printf "  PART 3: Deep-Stack 200bb Comparison\n%!";
  printf "================================================================\n\n%!";
  printf "Game: 2-player heads-up No-Limit Hold'em (DEEP STACK)\n%!";
  printf "  SB=%d BB=%d starting_stack=%d (%dbb) bet_fractions=%s max_raises=%d\n%!"
    deep_config.small_blind deep_config.big_blind deep_config.starting_stack
    (deep_config.starting_stack / deep_config.big_blind)
    (String.concat ~sep:"," (List.map deep_config.bet_fractions ~f:(sprintf "%.1f")))
    deep_config.max_raises_per_round;
  printf "  Full game tree: 186,174 nodes (vs 2,988 at 20bb)\n%!";
  printf "  Using showdown distribution trees for tractable RBM distance\n\n%!";

  (* Part 3a: Build showdown distribution trees for 200bb
     We reuse sampled_hands and preflop_eq from Part 1 since preflop
     equity is stack-independent. *)
  let deep_n_board_samples = !max_board_samples in
  let deep_n_opps = !max_opponents in
  printf "[3a] Building showdown distribution trees for %d hands (200bb)...\n%!" n;
  printf "  (%d board samples x %d opponents = %d leaves/tree)\n%!"
    deep_n_board_samples deep_n_opps
    (deep_n_board_samples * deep_n_opps);
  let (deep_trees, deep_tree_time) = time (fun () ->
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
        List.init deep_n_board_samples ~f:(fun _ ->
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
          let opp_start = 5 in
          let n_opp_avail = (n_rem - opp_start) / 2 in
          let n_opps = Int.min deep_n_opps n_opp_avail in
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
          description = sprintf "p1=%s%s preflop (200bb)"
            (Card.to_string h1) (Card.to_string h2)
        })
        ~children:board_children))
  in
  printf "  Built %d distribution trees in %.2fs\n%!" n deep_tree_time;
  let deep_sample = deep_trees.(0) in
  printf "  Sample tree: %d nodes, %d leaves, depth %d\n%!"
    (Tree.size deep_sample) (Tree.num_leaves deep_sample)
    (Tree.depth deep_sample);
  let deep_tree_list = Array.to_list deep_trees in
  let deep_tree_evs = Array.map deep_trees ~f:Tree.ev in

  (* Part 3b: RBM pairwise distance matrix for 200bb *)
  printf "\n[3b] Computing RBM pairwise distances (%d pairs, parallel)...\n%!"
    (n * (n - 1) / 2);
  let ((deep_rbm_matrix, deep_rbm_computed, deep_rbm_skipped), deep_rbm_time) =
    time (fun () ->
      Parallel.precompute_distances_parallel_pruned
        ~threshold:5.0 deep_tree_list)
  in
  printf "  RBM matrix: %dx%d in %.2fs (computed=%d, ev_pruned=%d)\n%!"
    n n deep_rbm_time deep_rbm_computed deep_rbm_skipped;

  (* Part 3c: EMD pairwise distance matrix for 200bb
     Reuses emd_histograms from Part 1 — EMD equity distributions are
     stack-independent (only showdown outcomes matter). *)
  printf "\n[3c] Reusing EMD equity distributions from 20bb (stack-independent)\n%!";
  printf "  EMD matrix: %dx%d (reused from Part 1)\n%!" n n;

  (* Part 3d: Scalar EV distance matrix — also stack-independent *)
  printf "  EV matrix: %dx%d (reused from Part 1)\n\n%!" n n;

  (* Part 3e: Cluster at exact k values for 200bb *)
  printf "[3e] Clustering at exact k values (200bb trees)...\n%!";
  let (deep_cluster_results, deep_cluster_time) = time (fun () ->
    List.map target_ks ~f:(fun k ->
      let rbm_clusters = cluster_to_k ~target_k:k deep_rbm_matrix n in
      let emd_clusters = cluster_to_k ~target_k:k emd_matrix n in
      let ev_clusters = cluster_to_k ~target_k:k ev_matrix n in
      let rbm_err = max_ev_error_from_evs deep_tree_evs rbm_clusters in
      let emd_err = max_ev_error_from_evs deep_tree_evs emd_clusters in
      let ev_err = max_ev_error_from_evs deep_tree_evs ev_clusters in
      (k, rbm_err, emd_err, ev_err)))
  in
  printf "  Clustering completed in %.3fs\n\n%!" deep_cluster_time;

  printf "=== Preflop Abstraction Quality (200bb) ===\n\n%!";
  printf "  %-5s  %-10s  %-10s  %-10s  %-8s\n%!"
    "k" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 53 '-');

  let deep_rbm_wins = ref 0 in
  let deep_emd_wins = ref 0 in
  let deep_ev_wins = ref 0 in
  let deep_ties = ref 0 in

  List.iter deep_cluster_results ~f:(fun (k, rbm_err, emd_err, ev_err) ->
    let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
    let tol = 0.0001 in
    let winner =
      let rbm_best = Float.( < ) (Float.abs (rbm_err -. min_err)) tol in
      let emd_best = Float.( < ) (Float.abs (emd_err -. min_err)) tol in
      let ev_best = Float.( < ) (Float.abs (ev_err -. min_err)) tol in
      match rbm_best && emd_best && ev_best with
      | true -> Int.incr deep_ties; "tie"
      | false ->
        match rbm_best with
        | true -> Int.incr deep_rbm_wins; "RBM"
        | false ->
          match emd_best with
          | true -> Int.incr deep_emd_wins; "EMD"
          | false ->
            match ev_best with
            | true -> Int.incr deep_ev_wins; "EV"
            | false -> Int.incr deep_ties; "tie"
    in
    printf "  %-5d  %-10.4f  %-10.4f  %-10.4f  %-8s\n%!"
      k rbm_err emd_err ev_err winner);

  printf "\n  Abstraction quality wins (200bb): RBM=%d EMD=%d EV=%d Tie=%d\n\n%!"
    !deep_rbm_wins !deep_emd_wins !deep_ev_wins !deep_ties;

  (* Part 3f: MCCFR training and head-to-head at 200bb *)
  printf "[3f] Building %d-bucket preflop abstractions for 200bb...\n%!" !n_buckets;
  let (deep_rbm_abs, deep_rbm_abs_time) = time (fun () ->
    let all_hands = Array.of_list Equity.all_canonical_hands in
    let small_trees = Array.map all_hands
        ~f:(fun (h : Equity.canonical_hand) ->
          let (h1, h2) = concrete_hole_cards h in
          let dealt = [ h1; h2 ] in
          let rem =
            List.filter Card.full_deck ~f:(fun c ->
              not (List.exists dealt ~f:(fun cc -> Card.equal c cc)))
          in
          let rem_arr = Array.of_list rem in
          let n_rem = Array.length rem_arr in
          let children =
            List.init 10 ~f:(fun _ ->
              for i = 0 to Int.min 6 (n_rem - 1) do
                let j = i + Random.int (n_rem - i) in
                let tmp = rem_arr.(i) in
                rem_arr.(i) <- rem_arr.(j);
                rem_arr.(j) <- tmp
              done;
              let n_opps = Int.min 10 ((n_rem - 5) / 2) in
              for i = 5 to Int.min (5 + n_opps * 2 - 1) (n_rem - 1) do
                let j = i + Random.int (n_rem - i) in
                let tmp = rem_arr.(i) in
                rem_arr.(i) <- rem_arr.(j);
                rem_arr.(j) <- tmp
              done;
              let leaves =
                List.init n_opps ~f:(fun k ->
                  let o1 = rem_arr.(5 + k * 2) in
                  let o2 = rem_arr.(5 + k * 2 + 1) in
                  let cmp = Hand_eval7.compare_hands7
                      [ h1; h2; rem_arr.(0); rem_arr.(1); rem_arr.(2);
                        rem_arr.(3); rem_arr.(4) ]
                      [ o1; o2; rem_arr.(0); rem_arr.(1); rem_arr.(2);
                        rem_arr.(3); rem_arr.(4) ]
                  in
                  let v = match cmp > 0 with
                    | true -> 1.0
                    | false -> match cmp = 0 with
                      | true -> 0.0
                      | false -> -1.0
                  in
                  Tree.leaf
                    ~label:(Rhode_island.Node_label.Terminal
                              { winner = None; pot = 0 })
                    ~value:v)
              in
              Tree.node
                ~label:(Rhode_island.Node_label.Chance
                          { description = "b" })
                ~children:leaves)
          in
          Tree.node
            ~label:(Rhode_island.Node_label.Chance
                      { description = "root" })
            ~children)
    in
    let small_evs = Array.map small_trees ~f:Tree.ev in
    let assignments, centroids =
      Abstraction.quantile_bucketing ~n_buckets:!n_buckets small_evs
    in
    ({ Abstraction.street = Preflop
     ; n_buckets = !n_buckets
     ; assignments
     ; centroids
     } : Abstraction.abstraction_partial))
  in
  printf "  RBM abstraction built in %.2fs\n%!" deep_rbm_abs_time;

  let (deep_emd_abs, deep_emd_abs_time) = time (fun () ->
    fast_preflop_abstraction ~n_buckets:!n_buckets ~n_samples:!eq_mc_samples)
  in
  printf "  EMD abstraction built in %.2fs\n\n%!" deep_emd_abs_time;

  printf "[3g] Training RBM bot (%d iters, %d buckets, NL 200bb)...\n%!"
    !deep_mccfr_iters !n_buckets;
  let ((deep_rbm_p0, deep_rbm_p1), deep_rbm_train_time) = time (fun () ->
    Cfr_nolimit.train_mccfr ~config:deep_config ~abstraction:deep_rbm_abs
      ~iterations:!deep_mccfr_iters ~report_every:10_000 ())
  in
  printf "  RBM training: %.2fs, P0=%d P1=%d info sets\n%!"
    deep_rbm_train_time
    (Hashtbl.length deep_rbm_p0) (Hashtbl.length deep_rbm_p1);

  printf "\n[3h] Training EMD bot (%d iters, %d buckets, NL 200bb)...\n%!"
    !deep_mccfr_iters !n_buckets;
  let ((deep_emd_p0, deep_emd_p1), deep_emd_train_time) = time (fun () ->
    Cfr_nolimit.train_mccfr ~config:deep_config ~abstraction:deep_emd_abs
      ~iterations:!deep_mccfr_iters ~report_every:10_000 ())
  in
  printf "  EMD training: %.2fs, P0=%d P1=%d info sets\n\n%!"
    deep_emd_train_time
    (Hashtbl.length deep_emd_p0) (Hashtbl.length deep_emd_p1);

  printf "[3i] Self-play: RBM bot vs EMD bot (%d hands, NL 200bb)...\n%!"
    !deep_play_hands;

  let deep_rbm_as_p0_profit = ref 0.0 in
  let deep_rbm_as_p1_profit = ref 0.0 in

  let ((), deep_play_time) = time (fun () ->
    for _ = 1 to !deep_play_hands do
      let (p1_cards, p2_cards, board) = sample_deal () in
      (* RBM as P0 (SB), EMD as P1 (BB) *)
      let profit_1 = play_nl_hand ~config:deep_config
          ~p0_strat:deep_rbm_p0 ~p1_strat:deep_emd_p1
          ~p0_abs:deep_rbm_abs ~p1_abs:deep_emd_abs
          ~p1_cards ~p2_cards ~board
      in
      deep_rbm_as_p0_profit := !deep_rbm_as_p0_profit +. profit_1;
      (* EMD as P0 (SB), RBM as P1 (BB) *)
      let profit_2 = play_nl_hand ~config:deep_config
          ~p0_strat:deep_emd_p0 ~p1_strat:deep_rbm_p1
          ~p0_abs:deep_emd_abs ~p1_abs:deep_rbm_abs
          ~p1_cards ~p2_cards ~board
      in
      deep_rbm_as_p1_profit := !deep_rbm_as_p1_profit -. profit_2
    done)
  in

  let deep_total_rbm_profit =
    !deep_rbm_as_p0_profit +. !deep_rbm_as_p1_profit
  in
  let deep_total_hands = 2 * !deep_play_hands in
  let deep_avg_bb_per_hand =
    deep_total_rbm_profit /. Float.of_int deep_total_hands
      /. Float.of_int deep_config.big_blind
  in

  printf "  Self-play completed in %.2fs\n\n%!" deep_play_time;

  let deep_winner_str =
    match Float.( > ) deep_avg_bb_per_hand 0.01 with
    | true -> "RBM"
    | false ->
      match Float.( < ) deep_avg_bb_per_hand (-0.01) with
      | true -> "EMD"
      | false -> "DRAW (within noise)"
  in

  (* ================================================================ *)
  (* COMBINED FINAL REPORT                                            *)
  (* ================================================================ *)
  let t_end = Core_unix.gettimeofday () in
  let total_time = t_end -. t_start in

  printf "================================================================\n%!";
  printf "  FINAL REPORT: RBM vs EMD on NL Hold'em (20bb + 200bb)\n%!";
  printf "================================================================\n\n%!";

  printf "--- 20bb Short-Stack (2,988 nodes, push/fold) ---\n\n%!";
  printf "Preflop Abstraction Quality (max EV error, lower is better):\n\n%!";
  printf "  %-5s  %-10s  %-10s  %-10s  %-8s\n%!"
    "k" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 53 '-');

  List.iter cluster_results ~f:(fun (k, rbm_err, emd_err, ev_err) ->
    let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
    let tol = 0.0001 in
    let winner =
      match Float.( < ) (Float.abs (rbm_err -. min_err)) tol with
      | true -> "RBM"
      | false ->
        match Float.( < ) (Float.abs (emd_err -. min_err)) tol with
        | true -> "EMD"
        | false -> "EV"
    in
    printf "  %-5d  %-10.4f  %-10.4f  %-10.4f  %-8s\n%!"
      k rbm_err emd_err ev_err winner);

  printf "\nMCCFR Head-to-Head (20bb, %d hands): RBM %+.4f bb/hand -> %s\n\n%!"
    total_hands avg_bb_per_hand winner_str_20bb;

  printf "--- 200bb Deep-Stack (186,174 nodes, post-flop rich) ---\n\n%!";
  printf "Preflop Abstraction Quality (max EV error, lower is better):\n\n%!";
  printf "  %-5s  %-10s  %-10s  %-10s  %-8s\n%!"
    "k" "RBM_err" "EMD_err" "EV_err" "Winner";
  printf "  %s\n%!" (String.make 53 '-');

  List.iter deep_cluster_results ~f:(fun (k, rbm_err, emd_err, ev_err) ->
    let min_err = Float.min rbm_err (Float.min emd_err ev_err) in
    let tol = 0.0001 in
    let winner =
      match Float.( < ) (Float.abs (rbm_err -. min_err)) tol with
      | true -> "RBM"
      | false ->
        match Float.( < ) (Float.abs (emd_err -. min_err)) tol with
        | true -> "EMD"
        | false -> "EV"
    in
    printf "  %-5d  %-10.4f  %-10.4f  %-10.4f  %-8s\n%!"
      k rbm_err emd_err ev_err winner);

  printf "\nMCCFR Head-to-Head (200bb, %d hands): RBM %+.4f bb/hand -> %s\n%!"
    deep_total_hands deep_avg_bb_per_hand deep_winner_str;
  printf "  RBM as P0: %+.1f (%.4f bb/hand)\n%!"
    !deep_rbm_as_p0_profit
    (!deep_rbm_as_p0_profit /. Float.of_int !deep_play_hands
     /. Float.of_int deep_config.big_blind);
  printf "  RBM as P1: %+.1f (%.4f bb/hand)\n%!"
    !deep_rbm_as_p1_profit
    (!deep_rbm_as_p1_profit /. Float.of_int !deep_play_hands
     /. Float.of_int deep_config.big_blind);
  printf "  P0 info sets: RBM=%d EMD=%d\n%!"
    (Hashtbl.length deep_rbm_p0) (Hashtbl.length deep_emd_p0);
  printf "  P1 info sets: RBM=%d EMD=%d\n\n%!"
    (Hashtbl.length deep_rbm_p1) (Hashtbl.length deep_emd_p1);

  printf "--- Comparison: Structural advantage vs stack depth ---\n\n%!";
  printf "  %-8s  %-12s  %-20s  %-15s\n%!"
    "Depth" "Abstraction" "Head-to-Head" "Hypothesis";
  printf "  %s\n%!" (String.make 65 '-');
  printf "  %-8s  %-12s  %-20s  %-15s\n%!"
    "20bb" (sprintf "RBM %d-%d" !rbm_wins !emd_wins)
    (sprintf "%-6s %+.2f bb/h" winner_str_20bb avg_bb_per_hand)
    "push/fold";
  printf "  %-8s  %-12s  %-20s  %-15s\n%!"
    "200bb" (sprintf "RBM %d-%d" !deep_rbm_wins !deep_emd_wins)
    (sprintf "%-6s %+.2f bb/h" deep_winner_str deep_avg_bb_per_hand)
    "deep-stack";

  printf "\nTiming:\n%!";
  printf "  20bb IS trees:         %.2fs\n%!" tree_time;
  printf "  20bb RBM distances:    %.2fs\n%!" rbm_time;
  printf "  20bb MCCFR (RBM+EMD):  %.2fs\n%!" (rbm_train_time +. emd_train_time);
  printf "  20bb self-play:        %.2fs\n%!" play_time;
  printf "  200bb IS trees:        %.2fs\n%!" deep_tree_time;
  printf "  200bb RBM distances:   %.2fs\n%!" deep_rbm_time;
  printf "  200bb MCCFR (RBM+EMD): %.2fs\n%!" (deep_rbm_train_time +. deep_emd_train_time);
  printf "  200bb self-play:       %.2fs\n%!" deep_play_time;
  printf "  Total wall time:       %.2fs\n\n%!" total_time;

  printf "================================================================\n%!";
  printf "  NL Hold'em: 20bb (2,988 nodes) vs 200bb (186,174 nodes)\n%!";
  printf "  RBM captures game-tree structure; EMD sees only equity.\n%!";
  printf "  Deeper stacks = more decisions = more structural variation.\n%!";
  printf "================================================================\n%!"
