(** Bot vs Bot self-play harness for Limit Hold'em.

    Trains strategies via MCCFR and plays N hands between them,
    reporting win rate, average profit, and sample hands.

    Usage:
      ./bot_vs_bot.exe --iterations 50000 --hands 10000 --buckets 10 *)

open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

(* ------------------------------------------------------------------ *)
(* Card utilities                                                      *)
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
(* Action selection from strategy                                      *)
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

(* ------------------------------------------------------------------ *)
(* Self-play simulation                                                *)
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

type hand_result = {
  p1_profit : float;
  action_history : string;
  p1_cards : Card.t * Card.t;
  p2_cards : Card.t * Card.t;
  board : Card.t list;
}

let action_char (a : Rhode_island.Action.t) =
  match a with
  | Fold -> "f"
  | Check -> "k"
  | Call -> "c"
  | Bet -> "b"
  | Raise -> "r"

let bet_size_for_round (config : Limit_holdem.config) round_idx =
  match round_idx with
  | 0 | 1 -> config.small_bet
  | _ -> config.big_bet

let play_hand
    ~(config : Limit_holdem.config)
    ~(p0_strat : Cfr_abstract.strategy)
    ~(p1_strat : Cfr_abstract.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
  : hand_result =
  let p1_buckets = Cfr_abstract.precompute_buckets ~abstraction ~hole_cards:p1_cards ~board in
  let p2_buckets = Cfr_abstract.precompute_buckets ~abstraction ~hole_cards:p2_cards ~board in
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
           | false -> Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
        | None -> Array.create ~len:num_actions (1.0 /. Float.of_int num_actions)
      in
      let action_idx = sample_action probs ~n_actions:num_actions in
      (match action_idx with
       | 0 ->
         Buffer.add_string history (action_char Fold);
         let pot = state.p1_invested + state.p2_invested in
         let winner = 1 - player in
         (match winner with
          | 0 -> Float.of_int (pot / 2)
          | _ -> Float.of_int (-(pot / 2)))
       | 1 ->
         Buffer.add_string history (action_char Call);
         let call_state = {
           state with
           bet_outstanding = false;
           p1_invested = (match player with 0 -> state.p1_invested + bet_sz | _ -> state.p1_invested);
           p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + bet_sz);
         } in
         advance_round call_state
       | _ ->
         Buffer.add_string history (action_char Raise);
         let raise_state = {
           state with
           to_act = 1 - player;
           num_raises = state.num_raises + 1;
           bet_outstanding = true;
           p1_invested = (match player with 0 -> state.p1_invested + 2 * bet_sz | _ -> state.p1_invested);
           p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + 2 * bet_sz);
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
           | false -> Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
        | None -> Array.create ~len:num_actions (1.0 /. Float.of_int num_actions)
      in
      let action_idx = sample_action probs ~n_actions:num_actions in
      (match action_idx with
       | 0 ->
         Buffer.add_string history (action_char Check);
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
         Buffer.add_string history (action_char Bet);
         let bet_state = {
           state with
           to_act = 1 - player;
           num_raises = state.num_raises + 1;
           bet_outstanding = true;
           first_checked = false;
           p1_invested = (match player with 0 -> state.p1_invested + bet_sz | _ -> state.p1_invested);
           p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + bet_sz);
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
  let p1_profit = play_round initial_state in
  { p1_profit;
    action_history = Buffer.contents history;
    p1_cards;
    p2_cards;
    board;
  }

(* ------------------------------------------------------------------ *)
(* Statistics and reporting                                             *)
(* ------------------------------------------------------------------ *)

let format_cards (c1, c2) =
  Card.to_string c1 ^ Card.to_string c2

let format_board board =
  String.concat ~sep:" " (List.map board ~f:Card.to_string)

let () =
  let iterations = ref 50_000 in
  let n_hands = ref 10_000 in
  let n_buckets = ref 10 in
  let verbose = ref false in

  let args = [
    ("--iterations", Arg.Set_int iterations,
     "N  MCCFR training iterations (default: 50000)");
    ("--hands", Arg.Set_int n_hands,
     "N  Number of self-play hands (default: 10000)");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Number of abstraction buckets (default: 10)");
    ("--verbose", Arg.Set verbose,
     "  Print every hand");
  ] in
  Arg.parse args (fun _ -> ()) "bot_vs_bot.exe [options]";

  let config = Limit_holdem.standard_config in

  printf "=== Bot vs Bot: Limit Hold'em Self-Play ===\n\n%!";
  printf "Config: SB=%d BB=%d small_bet=%d big_bet=%d max_raises=%d\n%!"
    config.small_blind config.big_blind config.small_bet config.big_bet config.max_raises;
  printf "Abstraction: %d preflop buckets\n%!" !n_buckets;
  printf "Training: %d MCCFR iterations\n\n%!" !iterations;

  let preflop_abs = Abstraction.abstract_preflop_equity ~n_buckets:!n_buckets in
  let ((p0_strat, p1_strat), train_wall) = time (fun () ->
    Cfr_abstract.train_mccfr ~config ~abstraction:preflop_abs
      ~iterations:!iterations ~report_every:10_000 ())
  in
  printf "Training complete in %.2fs\n%!" train_wall;
  printf "  P0 info sets: %d\n%!" (Hashtbl.length p0_strat);
  printf "  P1 info sets: %d\n\n%!" (Hashtbl.length p1_strat);

  printf "Playing %d hands...\n\n%!" !n_hands;

  let total_profit = ref 0.0 in
  let p0_wins = ref 0 in
  let p1_wins = ref 0 in
  let draws = ref 0 in
  let folds = ref 0 in
  let showdowns = ref 0 in
  let sample_hands = Queue.create () in

  let ((), play_wall) = time (fun () ->
    for hand_num = 1 to !n_hands do
      let (p1_cards, p2_cards, board) = sample_deal () in
      let result = play_hand ~config ~p0_strat ~p1_strat
          ~abstraction:preflop_abs ~p1_cards ~p2_cards ~board in

      total_profit := !total_profit +. result.p1_profit;
      (match Float.( > ) result.p1_profit 0.0 with
       | true -> Int.incr p0_wins
       | false ->
         match Float.( < ) result.p1_profit 0.0 with
         | true -> Int.incr p1_wins
         | false -> Int.incr draws);

      let has_fold = String.is_suffix result.action_history ~suffix:"f" in
      (match has_fold with
       | true -> Int.incr folds
       | false -> Int.incr showdowns);

      (match hand_num <= 10 || hand_num > !n_hands - 5 with
       | true -> Queue.enqueue sample_hands (hand_num, result)
       | false -> ());

      (match !verbose with
       | true ->
         printf "Hand %d: %s vs %s  Board: %s  Actions: %s  Profit: %+.1f\n%!"
           hand_num
           (format_cards result.p1_cards)
           (format_cards result.p2_cards)
           (format_board result.board)
           result.action_history
           result.p1_profit
       | false -> ())
    done)
  in

  printf "--- Results (%d hands, %.2fs) ---\n\n%!" !n_hands play_wall;

  let avg_profit = !total_profit /. Float.of_int !n_hands in
  printf "P0 (SB) total profit: %+.1f  average: %+.4f per hand\n%!" !total_profit avg_profit;
  printf "P0 wins: %d (%.1f%%)  P1 wins: %d (%.1f%%)  Draws: %d (%.1f%%)\n%!"
    !p0_wins (100.0 *. Float.of_int !p0_wins /. Float.of_int !n_hands)
    !p1_wins (100.0 *. Float.of_int !p1_wins /. Float.of_int !n_hands)
    !draws (100.0 *. Float.of_int !draws /. Float.of_int !n_hands);
  printf "Folds: %d (%.1f%%)  Showdowns: %d (%.1f%%)\n\n%!"
    !folds (100.0 *. Float.of_int !folds /. Float.of_int !n_hands)
    !showdowns (100.0 *. Float.of_int !showdowns /. Float.of_int !n_hands);

  printf "--- Sample Hands ---\n\n%!";
  printf "%6s  %8s  %8s  %-16s  %-24s  %8s\n%!"
    "Hand#" "P0" "P1" "Board" "Actions" "Profit";
  printf "%s\n%!" (String.make 80 '-');
  Queue.iter sample_hands ~f:(fun (num, result) ->
    printf "%6d  %8s  %8s  %-16s  %-24s  %+8.1f\n%!"
      num
      (format_cards result.p1_cards)
      (format_cards result.p2_cards)
      (format_board result.board)
      result.action_history
      result.p1_profit);

  printf "\n%!";

  let abs_avg = Float.abs avg_profit in
  (match Float.( < ) abs_avg 1.0 with
   | true ->
     printf "Sanity check PASSED: avg profit %.4f is close to 0 (fair game).\n%!" avg_profit
   | false ->
     printf "Note: avg profit %.4f is somewhat far from 0. With %d training iterations\n%!"
       avg_profit !iterations;
     printf "and %d buckets, strategy may not be fully converged.\n%!" !n_buckets);

  printf "\nDone.\n"
