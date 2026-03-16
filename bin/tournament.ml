(** Tournament: trains multiple MCCFR bots with different abstraction
    granularities and plays them round-robin to validate that more
    buckets generally means stronger play.

    Also includes two baseline bots (random, always-call) that require
    no training.

    Usage:
      ./tournament.exe [--iterations N] [--hands N] *)

open Rbm

(* ------------------------------------------------------------------ *)
(* Timing helper                                                       *)
(* ------------------------------------------------------------------ *)

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
(* Bot type: a strategy is just a function from info-key to probs      *)
(* ------------------------------------------------------------------ *)

(** A bot is a named entity that can produce action probabilities
    given an info-set key and number of available actions. *)
type bot = {
  name : string;
  (** Return action probabilities for [num_actions] actions at [key]. *)
  get_probs : key:Cfr_abstract.info_key -> num_actions:int -> float array;
  (** The abstraction used for bucket computation.  Baseline bots
      still need one to form info-set keys for the opponent lookup;
      we give them a trivial 1-bucket abstraction. *)
  abstraction : Abstraction.abstraction_partial;
}

(* ------------------------------------------------------------------ *)
(* MCCFR-trained bot                                                   *)
(* ------------------------------------------------------------------ *)

let make_mccfr_bot ~config ~n_buckets ~iterations : bot =
  let name = sprintf "%d-bucket" n_buckets in
  printf "Training %s bot (%d iterations)...\n%!" name iterations;
  let abstraction = Abstraction.abstract_preflop_equity ~n_buckets in
  let ((p0_strat, p1_strat), wall) = time (fun () ->
    Cfr_abstract.train_mccfr ~config ~abstraction
      ~iterations ~report_every:25_000 ())
  in
  printf "  %s trained in %.1fs  (P0 infosets=%d, P1 infosets=%d)\n%!"
    name wall (Hashtbl.length p0_strat) (Hashtbl.length p1_strat);
  (* Merge both positional strategies into a single lookup.
     During play, the bot may sit in either seat. The info-key
     encodes the bucket + history which already disambiguates
     position, so merging is safe. *)
  let merged = Hashtbl.Poly.create () in
  Hashtbl.iteri p0_strat ~f:(fun ~key ~data ->
    Hashtbl.set merged ~key ~data);
  Hashtbl.iteri p1_strat ~f:(fun ~key ~data ->
    match Hashtbl.mem merged key with
    | true -> ()  (* keep p0's version for shared keys *)
    | false -> Hashtbl.set merged ~key ~data);
  { name
  ; get_probs = (fun ~key ~num_actions ->
      match Hashtbl.find merged key with
      | Some p ->
        (match Array.length p = num_actions with
         | true -> p
         | false ->
           Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
      | None ->
        Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
  ; abstraction
  }

(* ------------------------------------------------------------------ *)
(* Baseline bots                                                       *)
(* ------------------------------------------------------------------ *)

let baseline_abstraction =
  Abstraction.abstract_preflop_equity ~n_buckets:1

let make_random_bot () : bot =
  { name = "random"
  ; get_probs = (fun ~key:_ ~num_actions ->
      Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
  ; abstraction = baseline_abstraction
  }

(** Always-call bot: never folds, never raises, always calls or checks.
    When facing a bet (actions = fold/call or fold/call/raise),
    always picks call (index 1).
    When no bet outstanding (actions = check or check/bet),
    always picks check (index 0). *)
let make_always_call_bot () : bot =
  { name = "always-call"
  ; get_probs = (fun ~key:_ ~num_actions ->
      (* We encode the policy as a probability distribution.
         The key insight: when bet_outstanding=true, action 0 = fold,
         1 = call, 2 = raise.  We want all mass on call.
         When bet_outstanding=false, action 0 = check, 1 = bet.
         We want all mass on check.

         Since we cannot tell which situation from num_actions alone
         (2 actions could be fold/call OR check/bet), we look at the key.
         If the key's last action before '|' was a bet/raise character,
         then there's a bet outstanding.  But simpler: for the always-call
         bot, we always pick action 0 when num_actions <= 2 with no bet
         outstanding, action 1 when facing a bet.

         Actually, we can distinguish by key content. But the simplest
         correct approach: always put mass on the "passive" action.
         - num_actions=1: only check available -> [1.0]
         - num_actions=2: could be fold/call or check/bet
           * fold/call: want call (idx 1) -> [0.0, 1.0]
           * check/bet: want check (idx 0) -> [1.0, 0.0]
         - num_actions=3: fold/call/raise -> want call (idx 1) -> [0.0, 1.0, 0.0]

         To distinguish the 2-action case, we check the info key.
         But we don't have access to the betting state here directly.
         Workaround: encode it in the key.

         Simpler approach: the play engine tells us whether bet_outstanding
         via the action count context.  Actually, looking at the play
         engine, the 2-action case is ambiguous.

         Best approach: encode "facing bet" in the key parsing.
         But for a baseline bot, let's use a different mechanism:
         check the key for bet-outstanding indicator. *)
      let probs = Array.create ~len:num_actions 0.0 in
      (match num_actions with
       | 1 ->
         (* Only check available *)
         probs.(0) <- 1.0
       | 3 ->
         (* fold/call/raise -> pick call *)
         probs.(1) <- 1.0
       | 2 ->
         (* Ambiguous: fold/call or check/bet.
            We'll handle this in the play engine by passing context.
            For now, we default to action 0 (check in check/bet case).
            The play engine for this bot will use a special path. *)
         probs.(0) <- 1.0
       | _ ->
         probs.(0) <- 1.0);
      probs)
  ; abstraction = baseline_abstraction
  }

(* ------------------------------------------------------------------ *)
(* Action sampling                                                     *)
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

(** Play a single hand.  p0_bot sits in seat 0 (SB), p1_bot in seat 1 (BB).
    Returns profit from P0's perspective (positive = P0 wins). *)
let play_hand
    ~(config : Limit_holdem.config)
    ~(p0_bot : bot)
    ~(p1_bot : bot)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
  : float =
  let p1_buckets =
    Cfr_abstract.precompute_buckets ~abstraction:p0_bot.abstraction
      ~hole_cards:p1_cards ~board
  in
  let p2_buckets =
    Cfr_abstract.precompute_buckets ~abstraction:p1_bot.abstraction
      ~hole_cards:p2_cards ~board
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
    let current_bot =
      match player with
      | 0 -> p0_bot
      | _ -> p1_bot
    in
    let key = Cfr_abstract.make_info_key ~buckets
        ~round_idx:state.round_idx
        ~history:(Buffer.contents history) in

    match state.bet_outstanding with
    | true ->
      let can_raise = state.num_raises < config.max_raises in
      let num_actions = match can_raise with true -> 3 | false -> 2 in
      (* Special handling for always-call bot facing a bet:
         In the 2-action case with bet outstanding, actions are fold/call.
         The always-call bot's get_probs returns [1.0, 0.0] for 2 actions
         (always picks idx 0), but here idx 0 = fold.  We need idx 1 = call.
         Fix: override for always-call when facing bet. *)
      let probs =
        match String.equal current_bot.name "always-call" with
        | true ->
          let p = Array.create ~len:num_actions 0.0 in
          p.(1) <- 1.0;  (* always call *)
          p
        | false ->
          current_bot.get_probs ~key ~num_actions
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
           p1_invested = (match player with
             | 0 -> state.p1_invested + bet_sz
             | _ -> state.p1_invested);
           p2_invested = (match player with
             | 0 -> state.p2_invested
             | _ -> state.p2_invested + bet_sz);
         } in
         advance_round call_state
       | _ ->
         Buffer.add_string history (action_char Raise);
         let raise_state = {
           state with
           to_act = 1 - player;
           num_raises = state.num_raises + 1;
           bet_outstanding = true;
           p1_invested = (match player with
             | 0 -> state.p1_invested + 2 * bet_sz
             | _ -> state.p1_invested);
           p2_invested = (match player with
             | 0 -> state.p2_invested
             | _ -> state.p2_invested + 2 * bet_sz);
         } in
         play_round raise_state)

    | false ->
      let can_bet = state.num_raises < config.max_raises in
      let num_actions = match can_bet with true -> 2 | false -> 1 in
      let probs = current_bot.get_probs ~key ~num_actions in
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
           p1_invested = (match player with
             | 0 -> state.p1_invested + bet_sz
             | _ -> state.p1_invested);
           p2_invested = (match player with
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
(* Matchup: play N hands between two bots, alternating positions       *)
(* ------------------------------------------------------------------ *)

(** Play [n_hands] between bot_a and bot_b, alternating who sits in
    seat 0 (SB) each hand.  Returns average profit for bot_a in
    big blinds per hand (bb/h). *)
let play_matchup ~config ~bot_a ~bot_b ~n_hands : float =
  let big_blind = Float.of_int config.Limit_holdem.big_blind in
  let total_profit_a = ref 0.0 in
  for hand_num = 1 to n_hands do
    let (p1_cards, p2_cards, board) = sample_deal () in
    (* Alternate positions: even hands bot_a is SB, odd hands bot_b is SB *)
    let profit =
      match hand_num % 2 = 0 with
      | true ->
        (* bot_a = SB (seat 0) *)
        play_hand ~config ~p0_bot:bot_a ~p1_bot:bot_b
          ~p1_cards ~p2_cards ~board
      | false ->
        (* bot_b = SB (seat 0), bot_a = BB (seat 1) *)
        let value = play_hand ~config ~p0_bot:bot_b ~p1_bot:bot_a
            ~p1_cards ~p2_cards ~board in
        Float.neg value  (* flip sign: value is from seat 0's perspective *)
    in
    total_profit_a := !total_profit_a +. profit
  done;
  (* Convert to bb/h *)
  !total_profit_a /. Float.of_int n_hands /. big_blind

(* ------------------------------------------------------------------ *)
(* Main tournament                                                     *)
(* ------------------------------------------------------------------ *)

let () =
  let iterations = ref 50_000 in
  let n_hands = ref 5_000 in

  let args = [
    ("--iterations", Arg.Set_int iterations,
     "N  MCCFR training iterations per bot (default: 50000)");
    ("--hands", Arg.Set_int n_hands,
     "N  Hands per matchup (default: 5000)");
  ] in
  Arg.parse args (fun _ -> ()) "tournament.exe [options]";

  let config = Limit_holdem.standard_config in

  printf "=== Poker Bot Tournament ===\n\n%!";
  printf "Config: SB=%d BB=%d small_bet=%d big_bet=%d max_raises=%d\n%!"
    config.small_blind config.big_blind config.small_bet config.big_bet
    config.max_raises;
  printf "Training: %d MCCFR iterations per bot\n%!" !iterations;
  printf "Matchups: %d hands each (alternating positions)\n\n%!" !n_hands;

  (* -------------------------------------------------------------- *)
  (* Train MCCFR bots                                                *)
  (* -------------------------------------------------------------- *)

  let bucket_counts = [ 5; 10; 20 ] in
  printf "--- Training Phase ---\n\n%!";

  let (mccfr_bots, total_train_wall) = time (fun () ->
    List.map bucket_counts ~f:(fun n_buckets ->
      make_mccfr_bot ~config ~n_buckets ~iterations:!iterations))
  in
  printf "\nTotal training time: %.1fs\n\n%!" total_train_wall;

  (* -------------------------------------------------------------- *)
  (* Create baseline bots                                            *)
  (* -------------------------------------------------------------- *)

  let random_bot = make_random_bot () in
  let always_call_bot = make_always_call_bot () in
  let all_bots = mccfr_bots @ [ random_bot; always_call_bot ] in
  let n_bots = List.length all_bots in
  let bot_names = List.map all_bots ~f:(fun b -> b.name) in

  (* -------------------------------------------------------------- *)
  (* Round-robin                                                     *)
  (* -------------------------------------------------------------- *)

  printf "--- Round-Robin Phase (%d matchups) ---\n\n%!"
    (n_bots * (n_bots - 1) / 2);

  (* results.(i).(j) = bot i's bb/h against bot j *)
  let results = Array.init n_bots ~f:(fun _ ->
    Array.create ~len:n_bots 0.0)
  in

  let bots_arr = Array.of_list all_bots in
  let ((), matchup_wall) = time (fun () ->
    for i = 0 to n_bots - 2 do
      for j = i + 1 to n_bots - 1 do
        let bot_a = bots_arr.(i) in
        let bot_b = bots_arr.(j) in
        printf "  %s vs %s ..." bot_a.name bot_b.name;
        let (bb_h, wall) = time (fun () ->
          play_matchup ~config ~bot_a ~bot_b ~n_hands:!n_hands)
        in
        results.(i).(j) <- bb_h;
        results.(j).(i) <- Float.neg bb_h;
        printf " %+.2f bb/h  (%.1fs)\n%!" bb_h wall
      done
    done)
  in
  printf "\nTotal matchup time: %.1fs\n\n%!" matchup_wall;

  (* -------------------------------------------------------------- *)
  (* Print results table                                             *)
  (* -------------------------------------------------------------- *)

  printf "=== Tournament Results (%d hands each matchup) ===\n\n%!" !n_hands;

  (* Compute column width: max of name lengths + padding *)
  let col_width = List.fold bot_names ~init:11 ~f:(fun acc name ->
    Int.max acc (String.length name + 2))
  in

  (* Header row *)
  printf "%*s" (col_width + 2) "";
  List.iter bot_names ~f:(fun name ->
    printf "%*s" col_width name);
  printf "  %*s\n%!" 8 "TOTAL";

  (* Data rows *)
  List.iteri bot_names ~f:(fun i name ->
    printf "  %-*s" col_width name;
    let total_bbh = ref 0.0 in
    List.iteri bot_names ~f:(fun j _opponent ->
      match i = j with
      | true ->
        printf "%*s" col_width "---"
      | false ->
        let v = results.(i).(j) in
        total_bbh := !total_bbh +. v;
        printf "%*s" col_width (sprintf "%+.2f" v));
    printf "  %+.2f\n%!" !total_bbh);

  printf "\n%!";

  (* -------------------------------------------------------------- *)
  (* Determine winner                                                *)
  (* -------------------------------------------------------------- *)

  let totals = Array.init n_bots ~f:(fun i ->
    Array.fold results.(i) ~init:0.0 ~f:( +. ))
  in
  let best_idx = ref 0 in
  let best_total = ref totals.(0) in
  Array.iteri totals ~f:(fun i t ->
    match Float.( > ) t !best_total with
    | true -> best_idx := i; best_total := t
    | false -> ());

  printf "Winner: %s (%+.2f total bb/h)\n\n%!"
    bots_arr.(!best_idx).name !best_total;

  (* -------------------------------------------------------------- *)
  (* Validation checks                                               *)
  (* -------------------------------------------------------------- *)

  printf "--- Validation ---\n\n%!";

  (* Check that MCCFR bots beat baselines *)
  let n_mccfr = List.length bucket_counts in
  let random_idx = n_mccfr in
  let call_idx = n_mccfr + 1 in
  let all_pass = ref true in

  List.iteri bucket_counts ~f:(fun i n_buckets ->
    let vs_random = results.(i).(random_idx) in
    let vs_call = results.(i).(call_idx) in
    let beats_random = Float.( > ) vs_random 0.0 in
    let beats_call = Float.( > ) vs_call 0.0 in
    let status r = match r with true -> "PASS" | false -> "FAIL" in
    printf "  %d-bucket vs random:      %+.2f bb/h  [%s]\n%!"
      n_buckets vs_random (status beats_random);
    printf "  %d-bucket vs always-call:  %+.2f bb/h  [%s]\n%!"
      n_buckets vs_call (status beats_call);
    (match beats_random && beats_call with
     | true -> ()
     | false -> all_pass := false));

  (* Check monotonicity: more buckets should generally be better *)
  printf "\n  Monotonicity (more buckets => higher total bb/h):\n%!";
  List.iteri bucket_counts ~f:(fun i n ->
    printf "    %d-bucket total: %+.2f bb/h\n%!" n totals.(i));

  let monotonic = ref true in
  for i = 0 to n_mccfr - 2 do
    match Float.( > ) totals.(i + 1) totals.(i) with
    | true -> ()
    | false -> monotonic := false
  done;
  printf "    Monotonic: %s\n%!"
    (match !monotonic with
     | true -> "YES (more buckets = better)"
     | false -> "NO (may need more iterations or hands for significance)");

  printf "\n%!";
  (match !all_pass with
   | true ->
     printf "All MCCFR bots beat both baselines. Tournament complete.\n%!"
   | false ->
     printf "Some MCCFR bots did not beat baselines. Consider increasing\n%!";
     printf "  --iterations or --hands for more reliable results.\n%!");

  printf "\nDone.\n%!"
