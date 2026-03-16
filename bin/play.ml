(** Interactive terminal Limit Hold'em: human vs trained MCCFR bot.

    Trains a quick strategy on startup (10K iterations, ~6s) or loads
    from a file, then deals hands interactively.  Shows bot strategy
    probabilities after each of its decisions for educational value. *)

open Rbm

(* ------------------------------------------------------------------ *)
(* Action encoding (mirrors action_char, not exposed)     *)
(* ------------------------------------------------------------------ *)

let action_char (a : Rhode_island.Action.t) =
  match a with
  | Fold  -> "f"
  | Check -> "k"
  | Call  -> "c"
  | Bet   -> "b"
  | Raise -> "r"

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

let format_card (c : Card.t) = Card.to_string c

let format_hole (c1, c2) =
  sprintf "[%s %s]" (format_card c1) (format_card c2)

let format_board cards =
  sprintf "[%s]" (String.concat ~sep:" " (List.map cards ~f:format_card))

(* ------------------------------------------------------------------ *)
(* Hand description for showdown                                       *)
(* ------------------------------------------------------------------ *)

let describe_hand (hole : Card.t * Card.t) (board : Card.t list) : string =
  let (h1, h2) = hole in
  let cards = [ h1; h2 ] @ board in
  let (rank, _tiebreakers) = Hand_eval7.evaluate7 cards in
  Hand_eval5.Hand_rank.to_string rank

(* ------------------------------------------------------------------ *)
(* Fast preflop abstraction (same as train_bot.ml)                     *)
(* ------------------------------------------------------------------ *)

let fast_preflop_equities ~n_samples =
  let n = List.length Equity.all_canonical_hands in
  let equities = Array.create ~len:n 0.0 in
  let deck = Array.of_list Card.full_deck in
  List.iter Equity.all_canonical_hands ~f:(fun (hand : Equity.canonical_hand) ->
    let h1, h2 =
      match Card.Rank.equal hand.rank1 hand.rank2 with
      | true ->
        ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
         { Card.rank = hand.rank2; suit = Card.Suit.Spades })
      | false ->
        match hand.suited with
        | true ->
          ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
           { Card.rank = hand.rank2; suit = Card.Suit.Hearts })
        | false ->
          ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
           { Card.rank = hand.rank2; suit = Card.Suit.Diamonds })
    in
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
      let b0 = remaining.(0) in
      let b1 = remaining.(1) in
      let b2 = remaining.(2) in
      let b3 = remaining.(3) in
      let b4 = remaining.(4) in
      let o1 = remaining.(5) in
      let o2 = remaining.(6) in
      let cmp = Equity.compare_7card
          (h1, h2, b0, b1, b2, b3, b4)
          (o1, o2, b0, b1, b2, b3, b4)
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
  let n = Array.length equities in
  let indexed = Array.init n ~f:(fun i -> (i, equities.(i))) in
  Array.sort indexed ~compare:(fun (_, e1) (_, e2) -> Float.compare e1 e2);
  let assignments = Hashtbl.Poly.create () in
  let centroids = Array.create ~len:n_buckets 0.0 in
  let bucket_counts = Array.create ~len:n_buckets 0 in
  let bucket_sums = Array.create ~len:n_buckets 0.0 in
  Array.iteri indexed ~f:(fun rank (hand_id, equity) ->
    let bucket = Int.min (n_buckets - 1) (rank * n_buckets / n) in
    Hashtbl.set assignments ~key:hand_id ~data:bucket;
    bucket_sums.(bucket) <- bucket_sums.(bucket) +. equity;
    bucket_counts.(bucket) <- bucket_counts.(bucket) + 1);
  Array.iteri bucket_counts ~f:(fun i count ->
    match count > 0 with
    | true -> centroids.(i) <- bucket_sums.(i) /. Float.of_int count
    | false -> centroids.(i) <- 0.0);
  ({ Abstraction.street = Preflop; n_buckets; assignments; centroids }
    : Abstraction.abstraction_partial)

(* ------------------------------------------------------------------ *)
(* Strategy I/O                                                        *)
(* ------------------------------------------------------------------ *)

let save_strategy ~filename (p0, p1) =
  let oc = Out_channel.create filename in
  Marshal.to_channel oc (p0, p1) [ Marshal.Closures ];
  Out_channel.close oc

let load_strategy ~filename : Cfr_abstract.strategy * Cfr_abstract.strategy =
  let ic = In_channel.create filename in
  let (p0, p1) = (Marshal.from_channel ic : Cfr_abstract.strategy * Cfr_abstract.strategy) in
  In_channel.close ic;
  (p0, p1)

(* ------------------------------------------------------------------ *)
(* Action sampling from strategy                                       *)
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
(* Prompt helpers                                                      *)
(* ------------------------------------------------------------------ *)

exception Quit

let read_line_safe () =
  match In_channel.(input_line stdin) with
  | Some line -> String.strip line
  | None -> raise Quit

let prompt_action ~(valid : (char * string) list) : char =
  let rec loop () =
    let options =
      List.map valid ~f:(fun (ch, name) -> sprintf "%c=%s" ch name)
      |> String.concat ~sep:", "
    in
    printf "Your action (%s, q=quit): %!" options;
    let input = read_line_safe () in
    match String.length input with
    | 0 -> printf "  Please enter an action.\n%!"; loop ()
    | _ ->
      let ch = Char.lowercase (String.get input 0) in
      (match Char.equal ch 'q' with
       | true -> raise Quit
       | false ->
         match List.exists valid ~f:(fun (v, _) -> Char.equal v ch) with
         | true -> ch
         | false ->
           printf "  Invalid choice '%c'. Try again.\n%!" ch;
           loop ())
  in
  loop ()

(* ------------------------------------------------------------------ *)
(* Strategy display                                                    *)
(* ------------------------------------------------------------------ *)

let format_strategy (probs : float array) (action_names : string list) : string =
  let parts =
    List.mapi action_names ~f:(fun i name ->
      match i < Array.length probs with
      | true -> sprintf "%s %.0f%%" name (probs.(i) *. 100.0)
      | false -> sprintf "%s ?%%" name)
  in
  String.concat ~sep:", " parts

(* ------------------------------------------------------------------ *)
(* Game state                                                          *)
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

let round_name = function
  | 0 -> "Preflop"
  | 1 -> "Flop"
  | 2 -> "Turn"
  | 3 -> "River"
  | _ -> "???"

(* ------------------------------------------------------------------ *)
(* Interactive hand play                                               *)
(* ------------------------------------------------------------------ *)

(** Play a single hand interactively.

    [human_seat] is 0 or 1 (0 = SB/first-to-act preflop, 1 = BB).
    Returns human's profit (positive = human won). *)
let play_interactive_hand
    ~(config : Limit_holdem.config)
    ~(p0_strat : Cfr_abstract.strategy)
    ~(p1_strat : Cfr_abstract.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(human_seat : int)
    ~(human_cards : Card.t * Card.t)
    ~(bot_cards : Card.t * Card.t)
    ~(board : Card.t list)
  : float =
  let bot_seat = 1 - human_seat in
  (* Assign cards: p1=seat0, p2=seat1 *)
  let p1_cards =
    match human_seat with
    | 0 -> human_cards
    | _ -> bot_cards
  in
  let p2_cards =
    match human_seat with
    | 0 -> bot_cards
    | _ -> human_cards
  in
  let p1_buckets =
    Cfr_abstract.precompute_buckets ~abstraction ~hole_cards:p1_cards ~board
  in
  let p2_buckets =
    Cfr_abstract.precompute_buckets ~abstraction ~hole_cards:p2_cards ~board
  in
  let history = Buffer.create 32 in

  (* Show the board for the current round *)
  let show_board round_idx pot =
    match round_idx with
    | 0 ->
      let sb_label =
        match human_seat with
        | 0 -> "you are SB=1, bot is BB=2"
        | _ -> "bot is SB=1, you are BB=2"
      in
      printf "%s - Pot: %d  (%s)\n%!" (round_name round_idx) pot sb_label
    | 1 ->
      let flop = List.take board 3 in
      printf "\n%s: %s  Pot: %d\n%!" (round_name round_idx) (format_board flop) pot
    | 2 ->
      let turn_card = List.nth_exn board 3 in
      printf "\n%s: %s  Pot: %d\n%!" (round_name round_idx)
        (format_board (List.take board 4))
        pot;
      printf "  (new card: %s)\n%!" (format_card turn_card)
    | 3 ->
      let river_card = List.nth_exn board 4 in
      printf "\n%s: %s  Pot: %d\n%!" (round_name round_idx)
        (format_board board) pot;
      printf "  (new card: %s)\n%!" (format_card river_card)
    | _ -> ()
  in

  let shown_rounds = Hashtbl.Poly.create () in

  let rec play_round (state : play_state) : float =
    let player = state.to_act in
    let pot = state.p1_invested + state.p2_invested in
    let bet_sz = bet_size_for_round config state.round_idx in

    (* Show board on first visit to a new round *)
    (match Hashtbl.mem shown_rounds state.round_idx with
     | true -> ()
     | false ->
       Hashtbl.set shown_rounds ~key:state.round_idx ~data:();
       show_board state.round_idx pot);

    let is_human = (player = human_seat) in

    match is_human with
    | true -> play_human_turn state ~pot ~bet_sz
    | false -> play_bot_turn state ~pot ~bet_sz

  and play_human_turn (state : play_state) ~pot ~bet_sz : float =
    let player = state.to_act in
    match state.bet_outstanding with
    | true ->
      let can_raise = state.num_raises < config.max_raises in
      let valid =
        match can_raise with
        | true -> [ ('f', "fold"); ('c', "call"); ('r', "raise") ]
        | false -> [ ('f', "fold"); ('c', "call") ]
      in
      let choice = prompt_action ~valid in
      (match choice with
       | 'f' ->
         Buffer.add_string history (action_char Fold);
         let winner = 1 - player in
         (* Return from seat-0 perspective *)
         (match winner with
          | 0 -> Float.of_int (pot / 2)
          | _ -> Float.of_int (-(pot / 2)))
       | 'c' ->
         printf "You call %d.\n%!" bet_sz;
         Buffer.add_string history (action_char Call);
         let call_state = {
           state with
           bet_outstanding = false;
           p1_invested = (match player with 0 -> state.p1_invested + bet_sz | _ -> state.p1_invested);
           p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + bet_sz);
         } in
         advance_round call_state
       | _ -> (* raise *)
         printf "You raise to %d.\n%!" (2 * bet_sz);
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
      let valid =
        match can_bet with
        | true -> [ ('k', "check"); ('b', "bet") ]
        | false -> [ ('k', "check") ]
      in
      let choice = prompt_action ~valid in
      (match choice with
       | 'k' ->
         printf "You check.\n%!";
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
       | _ -> (* bet *)
         printf "You bet %d.\n%!" bet_sz;
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

  and play_bot_turn (state : play_state) ~pot:_ ~bet_sz : float =
    let player = state.to_act in
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
      let action_names =
        match can_raise with
        | true -> [ "fold"; "call"; "raise" ]
        | false -> [ "fold"; "call" ]
      in
      let strat_str = format_strategy probs action_names in
      (match action_idx with
       | 0 ->
         Buffer.add_string history (action_char Fold);
         printf "Bot folds.  (strategy: %s)\n%!" strat_str;
         let winner = 1 - player in
         (match winner with
          | 0 -> Float.of_int ((state.p1_invested + state.p2_invested) / 2)
          | _ -> Float.of_int (-((state.p1_invested + state.p2_invested) / 2)))
       | 1 ->
         Buffer.add_string history (action_char Call);
         printf "Bot calls %d.  (strategy: %s)\n%!" bet_sz strat_str;
         let call_state = {
           state with
           bet_outstanding = false;
           p1_invested = (match player with 0 -> state.p1_invested + bet_sz | _ -> state.p1_invested);
           p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + bet_sz);
         } in
         advance_round call_state
       | _ ->
         Buffer.add_string history (action_char Raise);
         printf "Bot raises to %d.  (strategy: %s)\n%!" (2 * bet_sz) strat_str;
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
      let action_names =
        match can_bet with
        | true -> [ "check"; "bet" ]
        | false -> [ "check" ]
      in
      let strat_str = format_strategy probs action_names in
      (match action_idx with
       | 0 ->
         Buffer.add_string history (action_char Check);
         printf "Bot checks.  (strategy: %s)\n%!" strat_str;
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
         printf "Bot bets %d.  (strategy: %s)\n%!" bet_sz strat_str;
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
      (* Showdown *)
      let pot = state.p1_invested + state.p2_invested in
      printf "\n--- Showdown ---\n%!";
      let human_label =
        match human_seat with
        | 0 -> "You (SB)"
        | _ -> "You (BB)"
      in
      let bot_label =
        match bot_seat with
        | 0 -> "Bot (SB)"
        | _ -> "Bot (BB)"
      in
      printf "  %s:  %s  =  %s\n%!" human_label
        (format_hole human_cards) (describe_hand human_cards board);
      printf "  %s:  %s  =  %s\n%!" bot_label
        (format_hole bot_cards) (describe_hand bot_cards board);
      printf "  Board: %s\n%!" (format_board board);
      let (p1a, p1b) = p1_cards in
      let (p2a, p2b) = p2_cards in
      let hand1 = [ p1a; p1b ] @ board in
      let hand2 = [ p2a; p2b ] @ board in
      let cmp = Hand_eval7.compare_hands7 hand1 hand2 in
      (* p0_value is from seat-0 perspective *)
      let p0_value =
        match cmp > 0 with
        | true ->
          (match human_seat with
           | 0 -> printf "  You win pot of %d!\n%!" pot
           | _ -> printf "  Bot wins pot of %d!\n%!" pot);
          Float.of_int (pot / 2)
        | false ->
          match cmp < 0 with
          | true ->
            (match human_seat with
             | 0 -> printf "  Bot wins pot of %d!\n%!" pot
             | _ -> printf "  You win pot of %d!\n%!" pot);
            Float.of_int (-(pot / 2))
          | false ->
            printf "  Split pot! (%d each)\n%!" (pot / 2);
            0.0
      in
      p0_value
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
  (* p0_value is from seat-0 perspective; convert to human perspective *)
  let p0_value = play_round initial_state in
  match human_seat with
  | 0 -> p0_value
  | _ -> Float.neg p0_value

(* ------------------------------------------------------------------ *)
(* Main loop                                                           *)
(* ------------------------------------------------------------------ *)

let () =
  Random.self_init ();
  let strategy_file = ref "" in
  let iterations = ref 10_000 in
  let n_buckets = ref 10 in
  let n_samples = ref 2_000 in

  let args = [
    ("--load", Arg.Set_string strategy_file,
     "FILE  Load strategy from file instead of training");
    ("--iterations", Arg.Set_int iterations,
     "N  MCCFR training iterations (default: 10000)");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Abstraction buckets (default: 10)");
    ("--samples", Arg.Set_int n_samples,
     "N  MC samples for equity (default: 2000)");
  ] in
  Arg.parse args (fun _ -> ()) "play.exe [options]";

  let config = Limit_holdem.standard_config in

  printf "============================================\n%!";
  printf "    Limit Hold'em vs MCCFR Bot\n%!";
  printf "============================================\n%!";
  printf "Rules: SB=%d BB=%d  small_bet=%d big_bet=%d  max_raises=%d\n\n%!"
    config.small_blind config.big_blind config.small_bet config.big_bet
    config.max_raises;

  (* Build abstraction *)
  printf "Building preflop abstraction (%d buckets, %d MC samples)...\n%!"
    !n_buckets !n_samples;
  let t0 = Core_unix.gettimeofday () in
  let abstraction = fast_preflop_abstraction ~n_buckets:!n_buckets ~n_samples:!n_samples in
  let t1 = Core_unix.gettimeofday () in
  printf "  Done in %.2fs.\n\n%!" (t1 -. t0);

  (* Train or load strategy *)
  let (p0_strat, p1_strat) =
    match String.is_empty !strategy_file with
    | false ->
      printf "Loading strategy from %s...\n%!" !strategy_file;
      let strats = load_strategy ~filename:!strategy_file in
      printf "  Loaded.\n\n%!";
      strats
    | true ->
      printf "Training MCCFR (%d iterations)...\n%!" !iterations;
      let t2 = Core_unix.gettimeofday () in
      let strats =
        Cfr_abstract.train_mccfr ~config ~abstraction
          ~iterations:!iterations ~report_every:5_000 ()
      in
      let t3 = Core_unix.gettimeofday () in
      printf "  Done in %.2fs (%.0f iter/s).\n%!" (t3 -. t2)
        (Float.of_int !iterations /. (t3 -. t2));
      printf "  P0 info sets: %d  P1 info sets: %d\n\n%!"
        (Hashtbl.length (fst strats)) (Hashtbl.length (snd strats));
      (* Offer to save *)
      printf "Save strategy to file? (enter filename, or press Enter to skip): %!";
      let save_input = read_line_safe () in
      (match String.is_empty save_input with
       | true -> printf "  (not saved)\n\n%!"
       | false ->
         save_strategy ~filename:save_input strats;
         printf "  Saved to %s.\n\n%!" save_input);
      strats
  in

  printf "Ready to play! Dealer alternates each hand.\n%!";
  printf "============================================\n\n%!";

  let human_score = ref 0.0 in
  let bot_score = ref 0.0 in
  let hand_num = ref 0 in

  let print_final_score () =
    printf "\n============================================\n%!";
    printf "  Final score after %d hand%s:\n%!"
      !hand_num
      (match !hand_num with 1 -> "" | _ -> "s");
    printf "    You: %+.0f\n%!" !human_score;
    printf "    Bot: %+.0f\n%!" !bot_score;
    printf "============================================\n%!";
    printf "Thanks for playing!\n%!"
  in

  (try
    let keep_playing = ref true in
    while !keep_playing do
      Int.incr hand_num;
      let human_seat = (!hand_num - 1) % 2 in
      let (deal_p1, deal_p2, board) = sample_deal () in
      let (human_cards, bot_cards) =
        match human_seat with
        | 0 -> (deal_p1, deal_p2)
        | _ -> (deal_p2, deal_p1)
      in

      printf "=== Hand #%d ===" !hand_num;
      (match human_seat with
       | 0 -> printf "  (you are SB)\n%!"
       | _ -> printf "  (you are BB)\n%!");
      printf "Your hole cards: %s\n\n%!" (format_hole human_cards);

      let human_profit =
        play_interactive_hand ~config ~p0_strat ~p1_strat ~abstraction
          ~human_seat ~human_cards ~bot_cards ~board
      in
      human_score := !human_score +. human_profit;
      bot_score := !bot_score -. human_profit;

      printf "\n--------------------------------------------\n%!";
      (match Float.( > ) human_profit 0.0 with
       | true -> printf "  You won %+.0f this hand.\n%!" human_profit
       | false ->
         match Float.( < ) human_profit 0.0 with
         | true -> printf "  You lost %+.0f this hand.\n%!" human_profit
         | false -> printf "  Push (no profit/loss).\n%!");
      printf "  Score after %d hand%s: You %+.0f, Bot %+.0f\n%!"
        !hand_num
        (match !hand_num with 1 -> "" | _ -> "s")
        !human_score !bot_score;
      printf "--------------------------------------------\n\n%!";

      printf "Deal next hand? (y/n): %!";
      let answer = read_line_safe () in
      match String.length answer > 0 && Char.equal (Char.lowercase (String.get answer 0)) 'n' with
      | true -> keep_playing := false
      | false -> printf "\n%!"
    done;
    print_final_score ()
  with Quit ->
    printf "\n%!";
    print_final_score ())
