(** Surface sweep experiment: maps the full performance landscape across
    THREE dimensions: preflop bucket count, MCCFR training iterations,
    and RBM epsilon-based clustering threshold.

    Part 1 -- Bucket sweep (equity quantile):
      For each N in {5, 10, 20, 50, 100, 169} build an N-bucket preflop
      abstraction and train at {10K, 50K, 100K, 500K, 1M} iterations,
      then play 100 hands against Slumbot.

    Part 2 -- Epsilon sweep (RBM clustering):
      Build showdown distribution trees for all 169 canonical hands,
      compute the pairwise RBM distance matrix, then cluster at each
      epsilon in {0.01, 0.05, 0.1, 0.2, 0.5, 1.0}.  The resulting
      cluster count becomes the bucket count.  Train and play at
      {100K, 500K, 1M}.

    Part 3 -- Output:
      Print performance surface tables and save to results/surface_sweep.csv.

    Usage:
      opam exec -- dune exec -- rbm-surface-sweep
      opam exec -- dune exec -- rbm-surface-sweep --mock --buckets 5,10,20 --checkpoints 1000,5000 --hands 20
      opam exec -- dune exec -- rbm-surface-sweep --mock *)

open Rbm

(* ------------------------------------------------------------------ *)
(* Constants matching Slumbot's game                                   *)
(* ------------------------------------------------------------------ *)

let slumbot_small_blind = 50
let slumbot_big_blind = 100
let slumbot_stack = 20_000

let slumbot_config : Nolimit_holdem.config =
  { deck = Card.full_deck
  ; small_blind = slumbot_small_blind
  ; big_blind = slumbot_big_blind
  ; starting_stack = slumbot_stack
  ; bet_fractions = [ 0.5; 1.0; 2.0 ]
  ; max_raises_per_round = 4
  ; num_players = 2
  }

(* ------------------------------------------------------------------ *)
(* Timing                                                              *)
(* ------------------------------------------------------------------ *)

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

(* ------------------------------------------------------------------ *)
(* Format helpers                                                      *)
(* ------------------------------------------------------------------ *)

let format_int_with_commas n =
  let s = Int.to_string (Int.abs n) in
  let len = String.length s in
  let buf = Buffer.create (len + len / 3) in
  (match n < 0 with
   | true -> Buffer.add_char buf '-'
   | false -> ());
  String.iteri s ~f:(fun i c ->
    let pos_from_end = len - i in
    (match pos_from_end mod 3 = 0 && i > 0 with
     | true -> Buffer.add_char buf ','
     | false -> ());
    Buffer.add_char buf c);
  Buffer.contents buf

let format_info_sets n =
  match n >= 1_000_000 with
  | true -> sprintf "%.1fM" (Float.of_int n /. 1_000_000.0)
  | false ->
    match n >= 1_000 with
    | true -> sprintf "%.0fK" (Float.of_int n /. 1_000.0)
    | false -> Int.to_string n

let format_time_short secs =
  match Float.( >= ) secs 60.0 with
  | true -> sprintf "%.1fm" (secs /. 60.0)
  | false -> sprintf "%.0fs" secs

(* ------------------------------------------------------------------ *)
(* Strategy serialization                                              *)
(* ------------------------------------------------------------------ *)

let strategy_to_sexp (strat : Cfr_nolimit.strategy) : Sexp.t =
  let entries =
    Hashtbl.fold strat ~init:[] ~f:(fun ~key ~data acc ->
      let probs = List.map (Array.to_list data) ~f:(fun f ->
        Sexp.Atom (Float.to_string f)) in
      Sexp.List [ Sexp.Atom key; Sexp.List probs ] :: acc)
  in
  Sexp.List entries

let save_strategy ~filename (p0 : Cfr_nolimit.strategy) (p1 : Cfr_nolimit.strategy) =
  let sexp = Sexp.List [ strategy_to_sexp p0; strategy_to_sexp p1 ] in
  Out_channel.write_all filename ~data:(Sexp.to_string sexp)

(* ------------------------------------------------------------------ *)
(* Card parsing (Slumbot ACPC format)                                  *)
(* ------------------------------------------------------------------ *)

let parse_rank c =
  match c with
  | '2' -> Card.Rank.Two | '3' -> Three | '4' -> Four | '5' -> Five
  | '6' -> Six | '7' -> Seven | '8' -> Eight | '9' -> Nine
  | 'T' -> Ten | 'J' -> Jack | 'Q' -> Queen | 'K' -> King | 'A' -> Ace
  | _ -> failwithf "parse_rank: unknown rank '%c'" c ()

let parse_suit c =
  match c with
  | 'c' -> Card.Suit.Clubs | 'd' -> Diamonds
  | 'h' -> Hearts | 's' -> Spades
  | _ -> failwithf "parse_suit: unknown suit '%c'" c ()

let parse_card_string s =
  match String.length s >= 2 with
  | true ->
    let rank = parse_rank (String.get s 0) in
    let suit = parse_suit (String.get s 1) in
    { Card.rank; suit }
  | false -> failwithf "parse_card_string: too short %S" s ()

(* ------------------------------------------------------------------ *)
(* Slumbot action parsing                                              *)
(* ------------------------------------------------------------------ *)

type action_state = {
  street : int;
  pos : int;
  street_last_bet_to : int;
  total_last_bet_to : int;
  last_bet_size : int;
  last_bettor : int;
} [@@warning "-69"]

let parse_slumbot_action (action : string) : action_state =
  let st = ref 0 in
  let street_last_bet_to = ref slumbot_big_blind in
  let total_last_bet_to = ref slumbot_big_blind in
  let last_bet_size = ref (slumbot_big_blind - slumbot_small_blind) in
  let last_bettor = ref 0 in
  let pos = ref 1 in
  let sz = String.length action in
  let check_or_call_ends_street = ref false in
  let i = ref 0 in
  let error_state = ref false in
  while !i < sz && not !error_state do
    let c = String.get action !i in
    Int.incr i;
    match c with
    | 'k' ->
      (match !check_or_call_ends_street with
       | true ->
         (match !st < 3 && !i < sz with
          | true ->
            (match Char.equal (String.get action !i) '/' with
             | true -> Int.incr i
             | false -> ())
          | false -> ());
         (match !st >= 3 with
          | true -> pos := -1
          | false ->
            pos := 0;
            Int.incr st);
         street_last_bet_to := 0;
         last_bet_size := 0;
         last_bettor := -1;
         check_or_call_ends_street := false
       | false ->
         pos := (!pos + 1) mod 2;
         check_or_call_ends_street := true)
    | 'c' ->
      (match !total_last_bet_to = slumbot_stack with
       | true ->
         while !i < sz do
           (match Char.equal (String.get action !i) '/' with
            | true -> Int.incr i
            | false -> i := sz)
         done;
         st := 3;
         pos := -1;
         last_bet_size := 0
       | false ->
         (match !check_or_call_ends_street with
          | true ->
            (match !st < 3 && !i < sz with
             | true ->
               (match Char.equal (String.get action !i) '/' with
                | true -> Int.incr i
                | false -> ())
             | false -> ());
            (match !st >= 3 with
             | true -> pos := -1
             | false ->
               pos := 0;
               Int.incr st);
            street_last_bet_to := 0;
            check_or_call_ends_street := false
          | false ->
            pos := (!pos + 1) mod 2;
            check_or_call_ends_street := true);
         last_bet_size := 0;
         last_bettor := -1)
    | 'f' ->
      pos := -1;
      i := sz
    | 'b' ->
      let j = !i in
      while !i < sz
            && Char.( >= ) (String.get action !i) '0'
            && Char.( <= ) (String.get action !i) '9'
      do
        Int.incr i
      done;
      (match !i > j with
       | true ->
         let new_street_bet = Int.of_string (String.sub action ~pos:j ~len:(!i - j)) in
         let new_last_bet_size = new_street_bet - !street_last_bet_to in
         last_bet_size := new_last_bet_size;
         street_last_bet_to := new_street_bet;
         total_last_bet_to := !total_last_bet_to + new_last_bet_size;
         last_bettor := !pos;
         pos := (!pos + 1) mod 2;
         check_or_call_ends_street := true
       | false ->
         error_state := true)
    | '/' ->
      Int.incr st;
      street_last_bet_to := 0;
      pos := 0;
      check_or_call_ends_street := false
    | _ -> error_state := true
  done;
  { street = !st
  ; pos = !pos
  ; street_last_bet_to = !street_last_bet_to
  ; total_last_bet_to = !total_last_bet_to
  ; last_bet_size = !last_bet_size
  ; last_bettor = !last_bettor
  }

let is_our_turn (state : action_state) ~(client_pos : int) : bool =
  state.pos >= 0 && state.pos = client_pos

(* ------------------------------------------------------------------ *)
(* Slumbot action history -> internal history                          *)
(* ------------------------------------------------------------------ *)

let slumbot_action_to_internal_history (action : string) : string =
  let buf = Buffer.create (String.length action) in
  let i = ref 0 in
  let sz = String.length action in
  let street_pot = ref (slumbot_small_blind + slumbot_big_blind) in
  let street_invested = [| ref slumbot_small_blind; ref slumbot_big_blind |] in
  let cur_pos = ref 1 in
  while !i < sz do
    let c = String.get action !i in
    Int.incr i;
    match c with
    | 'k' ->
      Buffer.add_char buf 'k';
      cur_pos := (!cur_pos + 1) mod 2
    | 'c' ->
      Buffer.add_char buf 'c';
      let other = (!cur_pos + 1) mod 2 in
      let to_call = !(street_invested.(other)) - !(street_invested.(!cur_pos)) in
      street_invested.(!cur_pos) := !(street_invested.(!cur_pos)) + to_call;
      street_pot := !street_pot + to_call;
      cur_pos := (!cur_pos + 1) mod 2
    | 'f' ->
      Buffer.add_char buf 'f'
    | 'b' ->
      let j = !i in
      while !i < sz
            && Char.( >= ) (String.get action !i) '0'
            && Char.( <= ) (String.get action !i) '9'
      do
        Int.incr i
      done;
      let new_street_bet = Int.of_string (String.sub action ~pos:j ~len:(!i - j)) in
      let raise_amount = new_street_bet - !(street_invested.(!cur_pos)) in
      let pot_before = !street_pot in
      let frac =
        match pot_before > 0 with
        | true -> Float.of_int raise_amount /. Float.of_int pot_before
        | false -> 1.0
      in
      let hist_char =
        match Float.( >= ) frac 1.5 with
        | true ->
          (match new_street_bet >= slumbot_stack with
           | true -> 'a'
           | false -> 'd')
        | false ->
          match Float.( >= ) frac 0.75 with
          | true -> 'p'
          | false -> 'h'
      in
      Buffer.add_char buf hist_char;
      street_invested.(!cur_pos) := new_street_bet;
      street_pot := !street_pot + raise_amount;
      cur_pos := (!cur_pos + 1) mod 2
    | '/' ->
      Buffer.add_char buf '/';
      street_invested.(0) := 0;
      street_invested.(1) := 0;
      cur_pos := 0
    | _ -> ()
  done;
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Action selection using trained strategy                              *)
(* ------------------------------------------------------------------ *)

let select_slumbot_action
    ~(p0_strat : Cfr_nolimit.strategy)
    ~(p1_strat : Cfr_nolimit.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(client_pos : int)
    ~(action : string)
    ~(action_state : action_state)
  : string * string * float array =
  let buckets =
    Cfr_nolimit.precompute_buckets_equity ~abstraction ~hole_cards ~board
  in
  let round_idx = action_state.street in
  let internal_history = slumbot_action_to_internal_history action in
  let key = Cfr_nolimit.make_info_key ~buckets ~round_idx ~history:internal_history in
  let strategy =
    match client_pos with
    | 1 -> p0_strat
    | _ -> p1_strat
  in
  let facing_bet = action_state.last_bet_size > 0 in
  let actions = ref [] in
  (match facing_bet with
   | true -> actions := ("f", "f") :: !actions
   | false -> ());
  let check_call =
    match facing_bet with
    | true -> ("c", "c")
    | false -> ("k", "k")
  in
  actions := check_call :: !actions;
  let pot = action_state.total_last_bet_to * 2 in
  let to_call = action_state.last_bet_size in
  let remaining = slumbot_stack - action_state.total_last_bet_to in
  let can_raise = remaining > to_call in
  (match can_raise with
   | true ->
     List.iter [ (0.5, "h"); (1.0, "p"); (2.0, "d") ] ~f:(fun (frac, hist) ->
       let pot_after_call = pot + to_call in
       let raise_amount =
         Int.max slumbot_big_blind
           (Float.to_int (Float.of_int pot_after_call *. frac))
       in
       let new_bet = action_state.street_last_bet_to + to_call + raise_amount in
       let new_bet = Int.min new_bet (slumbot_stack - action_state.total_last_bet_to
                                      + action_state.street_last_bet_to) in
       match new_bet > action_state.street_last_bet_to && new_bet < slumbot_stack with
       | true ->
         actions := (sprintf "b%d" new_bet, hist) :: !actions
       | false -> ());
     (match remaining > 0 with
      | true ->
        let all_in_street_bet = action_state.street_last_bet_to + remaining in
        actions := (sprintf "b%d" all_in_street_bet, "a") :: !actions
      | false -> ())
   | false -> ());
  let actions = List.rev !actions in
  let action_arr = Array.of_list actions in
  let num_actions = Array.length action_arr in
  let probs =
    match Hashtbl.find strategy key with
    | Some p ->
      (match Array.length p = num_actions with
       | true -> p
       | false -> Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
    | None ->
      Array.create ~len:num_actions (1.0 /. Float.of_int num_actions)
  in
  let r = Random.float 1.0 in
  let cumulative = ref 0.0 in
  let chosen_idx = ref (num_actions - 1) in
  let found = ref false in
  Array.iteri action_arr ~f:(fun i _ ->
    match !found with
    | true -> ()
    | false ->
      cumulative := !cumulative +. probs.(i);
      match Float.( >= ) !cumulative r with
      | true -> chosen_idx := i; found := true
      | false -> ());
  let (slumbot_action, _hist) = action_arr.(!chosen_idx) in
  (slumbot_action, key, probs)

(* ------------------------------------------------------------------ *)
(* HTTP client (via curl) with retry                                   *)
(* ------------------------------------------------------------------ *)

let http_post_with_retry ~(url : string) ~(json_body : string)
    ~(max_retries : int) : (string, string) result =
  let escaped_body = String.concat_map json_body ~f:(fun c ->
    match Char.equal c '\'' with
    | true -> "'\\''"
    | false -> String.of_char c)
  in
  let cmd = sprintf
    "curl -s -m 30 -X POST '%s' -H 'Content-Type: application/json' -d '%s' 2>&1"
    url escaped_body
  in
  let rec try_request attempt =
    let ic = Core_unix.open_process_in cmd in
    let body = In_channel.input_all ic in
    let status = Core_unix.close_process_in ic in
    match status with
    | Ok () ->
      (match String.length body > 0 with
       | true -> Ok body
       | false ->
         match attempt < max_retries with
         | true ->
           eprintf "  [retry] empty response, attempt %d/%d\n%!" (attempt + 1) max_retries;
           Core_unix.sleep 2;
           try_request (attempt + 1)
         | false -> Error "empty response after retries")
    | Error _ ->
      match attempt < max_retries with
      | true ->
        eprintf "  [retry] curl failed, attempt %d/%d\n%!" (attempt + 1) max_retries;
        Core_unix.sleep 2;
        try_request (attempt + 1)
      | false -> Error (sprintf "curl failed after %d retries: %s" max_retries body)
  in
  try_request 1

(* ------------------------------------------------------------------ *)
(* JSON helpers                                                        *)
(* ------------------------------------------------------------------ *)

let json_of_string s =
  try Ok (Yojson.Safe.from_string s)
  with exn -> Error (Exn.to_string exn)

let json_string_field json field =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields ~equal:String.equal field with
     | Some (`String s) -> Some s
     | _ -> None)
  | _ -> None

let json_int_field json field =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields ~equal:String.equal field with
     | Some (`Int n) -> Some n
     | Some (`Float f) -> Some (Float.to_int f)
     | _ -> None)
  | _ -> None

let json_string_list_field json field =
  match json with
  | `Assoc fields ->
    (match List.Assoc.find fields ~equal:String.equal field with
     | Some (`List items) ->
       Some (List.filter_map items ~f:(fun item ->
         match item with
         | `String s -> Some s
         | _ -> None))
     | _ -> None)
  | _ -> None

let json_has_field json field =
  match json with
  | `Assoc fields ->
    List.Assoc.mem fields ~equal:String.equal field
  | _ -> false

(* ------------------------------------------------------------------ *)
(* Slumbot API                                                         *)
(* ------------------------------------------------------------------ *)

let slumbot_base_url = "https://slumbot.com/slumbot/api"

let slumbot_new_hand ~(token : string option) : Yojson.Safe.t =
  let body =
    match token with
    | Some t -> sprintf {|{"token": "%s"}|} t
    | None -> "{}"
  in
  let url = slumbot_base_url ^ "/new_hand" in
  match http_post_with_retry ~url ~json_body:body ~max_retries:3 with
  | Error msg -> failwithf "slumbot_new_hand failed: %s" msg ()
  | Ok response ->
    match json_of_string response with
    | Error msg -> failwithf "slumbot_new_hand: bad JSON: %s\nResponse: %s" msg response ()
    | Ok json ->
      (match json_string_field json "error_msg" with
       | Some err -> failwithf "slumbot_new_hand API error: %s" err ()
       | None -> json)

let slumbot_act ~(token : string) ~(incr : string) : Yojson.Safe.t =
  let body = sprintf {|{"token": "%s", "incr": "%s"}|} token incr in
  let url = slumbot_base_url ^ "/act" in
  match http_post_with_retry ~url ~json_body:body ~max_retries:3 with
  | Error msg -> failwithf "slumbot_act failed: %s" msg ()
  | Ok response ->
    match json_of_string response with
    | Error msg -> failwithf "slumbot_act: bad JSON: %s\nResponse: %s" msg response ()
    | Ok json ->
      (match json_string_field json "error_msg" with
       | Some err -> failwithf "slumbot_act API error: %s" err ()
       | None -> json)

(* ------------------------------------------------------------------ *)
(* Mock Slumbot (check/call bot for offline testing)                   *)
(* ------------------------------------------------------------------ *)

module Mock_slumbot = struct
  type hand_state = {
    mutable action : string;
    client_pos : int;
    hole_cards : Card.t * Card.t;
    opponent_cards : Card.t * Card.t;
    board : Card.t list;
    token : string;
  }

  let current_hand : hand_state option ref = ref None

  let shuffle_array arr =
    let n = Array.length arr in
    for i = n - 1 downto 1 do
      let j = Random.int (i + 1) in
      let tmp = arr.(i) in
      arr.(i) <- arr.(j);
      arr.(j) <- tmp
    done

  let deal () =
    let deck = Array.of_list Card.full_deck in
    shuffle_array deck;
    let client_cards = (deck.(0), deck.(1)) in
    let opp_cards = (deck.(2), deck.(3)) in
    let board = [ deck.(4); deck.(5); deck.(6); deck.(7); deck.(8) ] in
    (client_cards, opp_cards, board)

  let board_for_street board street =
    match street with
    | 0 -> []
    | 1 -> List.take board 3
    | 2 -> List.take board 4
    | _ -> board

  let card_to_slumbot c = Card.to_string c

  let new_hand ~(token : string option) : Yojson.Safe.t =
    let _ = token in
    let (client_cards, opp_cards, board) = deal () in
    let client_pos = Random.int 2 in
    let tok = sprintf "mock-%d" (Random.int 1_000_000) in
    let state = {
      action = "";
      client_pos;
      hole_cards = client_cards;
      opponent_cards = opp_cards;
      board;
      token = tok;
    } in
    current_hand := Some state;
    let initial_action =
      match client_pos with
      | 0 ->
        state.action <- "c";
        "c"
      | _ -> ""
    in
    let (c1, c2) = client_cards in
    `Assoc [
      ("token", `String tok);
      ("action", `String initial_action);
      ("client_pos", `Int client_pos);
      ("hole_cards", `List [ `String (card_to_slumbot c1);
                             `String (card_to_slumbot c2) ]);
      ("board", `List []);
      ("winnings", `Null);
    ]

  let evaluate_winner state =
    let (c1, c2) = state.hole_cards in
    let (o1, o2) = state.opponent_cards in
    let client_hand = [ c1; c2 ] @ state.board in
    let opp_hand = [ o1; o2 ] @ state.board in
    Hand_eval7.compare_hands7 client_hand opp_hand

  let act ~(token : string) ~(incr : string) : Yojson.Safe.t =
    let _ = token in
    match !current_hand with
    | None -> failwith "mock: no hand in progress"
    | Some state ->
      state.action <- state.action ^ incr;
      let a_state = parse_slumbot_action state.action in
      let (c1, c2) = state.hole_cards in
      let visible_board = board_for_street state.board a_state.street in
      match a_state.pos < 0 with
      | true ->
        let action = state.action in
        let has_fold = String.is_suffix action ~suffix:"f" in
        let winnings =
          match has_fold with
          | true ->
            let client_folded = String.is_suffix (String.rstrip incr) ~suffix:"f" in
            (match client_folded with
             | true -> - a_state.total_last_bet_to
             | false -> a_state.total_last_bet_to)
          | false ->
            let cmp = evaluate_winner state in
            (match cmp > 0 with
             | true -> a_state.total_last_bet_to
             | false ->
               match cmp < 0 with
               | true -> - a_state.total_last_bet_to
               | false -> 0)
        in
        let (o1, o2) = state.opponent_cards in
        `Assoc [
          ("token", `String state.token);
          ("action", `String state.action);
          ("client_pos", `Int state.client_pos);
          ("hole_cards", `List [ `String (card_to_slumbot c1);
                                 `String (card_to_slumbot c2) ]);
          ("board", `List (List.map state.board ~f:(fun c ->
             `String (card_to_slumbot c))));
          ("bot_hole_cards", `List [ `String (card_to_slumbot o1);
                                     `String (card_to_slumbot o2) ]);
          ("winnings", `Int winnings);
        ]
      | false ->
        let our_turn = is_our_turn a_state ~client_pos:state.client_pos in
        (match our_turn with
         | true ->
           `Assoc [
             ("token", `String state.token);
             ("action", `String state.action);
             ("client_pos", `Int state.client_pos);
             ("hole_cards", `List [ `String (card_to_slumbot c1);
                                    `String (card_to_slumbot c2) ]);
             ("board", `List (List.map visible_board ~f:(fun c ->
                `String (card_to_slumbot c))));
             ("winnings", `Null);
           ]
         | false ->
           let bot_incr =
             match a_state.last_bet_size > 0 with
             | true -> "c"
             | false -> "k"
           in
           state.action <- state.action ^ bot_incr;
           let new_a_state = parse_slumbot_action state.action in
           let new_visible_board = board_for_street state.board new_a_state.street in
           match new_a_state.pos < 0 with
           | true ->
             let cmp = evaluate_winner state in
             let winnings =
               match cmp > 0 with
               | true -> new_a_state.total_last_bet_to
               | false ->
                 match cmp < 0 with
                 | true -> - new_a_state.total_last_bet_to
                 | false -> 0
             in
             let (o1, o2) = state.opponent_cards in
             `Assoc [
               ("token", `String state.token);
               ("action", `String state.action);
               ("client_pos", `Int state.client_pos);
               ("hole_cards", `List [ `String (card_to_slumbot c1);
                                      `String (card_to_slumbot c2) ]);
               ("board", `List (List.map state.board ~f:(fun c ->
                  `String (card_to_slumbot c))));
               ("bot_hole_cards", `List [ `String (card_to_slumbot o1);
                                           `String (card_to_slumbot o2) ]);
               ("winnings", `Int winnings);
             ]
           | false ->
             `Assoc [
               ("token", `String state.token);
               ("action", `String state.action);
               ("client_pos", `Int state.client_pos);
               ("hole_cards", `List [ `String (card_to_slumbot c1);
                                      `String (card_to_slumbot c2) ]);
               ("board", `List (List.map new_visible_board ~f:(fun c ->
                  `String (card_to_slumbot c))));
               ("winnings", `Null);
             ])
end

(* ------------------------------------------------------------------ *)
(* Unified API                                                         *)
(* ------------------------------------------------------------------ *)

type api_mode = Real | Mock

let api_new_hand ~(mode : api_mode) ~(token : string option) =
  match mode with
  | Real -> slumbot_new_hand ~token
  | Mock -> Mock_slumbot.new_hand ~token

let api_act ~(mode : api_mode) ~(token : string) ~(incr : string) =
  match mode with
  | Real -> slumbot_act ~token ~incr
  | Mock -> Mock_slumbot.act ~token ~incr

(* ------------------------------------------------------------------ *)
(* Play a single hand against Slumbot (with error recovery)            *)
(* ------------------------------------------------------------------ *)

let play_hand
    ~(mode : api_mode)
    ~(token : string option)
    ~(p0_strat : Cfr_nolimit.strategy)
    ~(p1_strat : Cfr_nolimit.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
  : string option * int =
  let json = api_new_hand ~mode ~token in
  let new_token = json_string_field json "token" in
  let token = Option.value new_token ~default:(Option.value token ~default:"") in
  let client_pos =
    match json_int_field json "client_pos" with
    | Some p -> p
    | None -> 0
  in
  let hole_cards_strs =
    match json_string_list_field json "hole_cards" with
    | Some cards -> cards
    | None -> failwith "play_hand: no hole_cards in response"
  in
  let hole_cards =
    match hole_cards_strs with
    | [ c1; c2 ] -> (parse_card_string c1, parse_card_string c2)
    | _ -> failwithf "play_hand: expected 2 hole cards, got %d"
             (List.length hole_cards_strs) ()
  in
  let rec play_loop json =
    let action =
      match json_string_field json "action" with
      | Some a -> a
      | None -> ""
    in
    let board_strs =
      match json_string_list_field json "board" with
      | Some b -> b
      | None -> []
    in
    let board = List.map board_strs ~f:parse_card_string in
    match json_has_field json "winnings" && not (
      match json with
      | `Assoc fields ->
        (match List.Assoc.find fields ~equal:String.equal "winnings" with
         | Some `Null -> true
         | _ -> false)
      | _ -> true) with
    | true ->
      let winnings =
        match json_int_field json "winnings" with
        | Some w -> w
        | None -> 0
      in
      (Some token, winnings)
    | false ->
      let a_state = parse_slumbot_action action in
      let our_turn = is_our_turn a_state ~client_pos in
      (match our_turn with
       | false -> (Some token, 0)
       | true ->
         let (incr, _key, _probs) =
           select_slumbot_action
             ~p0_strat ~p1_strat ~abstraction
             ~hole_cards ~board ~client_pos ~action ~action_state:a_state
         in
         let response = api_act ~mode ~token ~incr in
         play_loop response)
  in
  play_loop json

(* ------------------------------------------------------------------ *)
(* Play N hands and return total winnings in chips                     *)
(* ------------------------------------------------------------------ *)

let play_session
    ~(mode : api_mode)
    ~(num_hands : int)
    ~(p0_strat : Cfr_nolimit.strategy)
    ~(p1_strat : Cfr_nolimit.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
  : int * float =
  let total_winnings = ref 0 in
  let token = ref None in
  let errors = ref 0 in
  let ((), elapsed) = time (fun () ->
    for _hand = 1 to num_hands do
      (try
         let (new_token, winnings) =
           play_hand ~mode ~token:!token ~p0_strat ~p1_strat ~abstraction
         in
         token := new_token;
         total_winnings := !total_winnings + winnings
       with exn ->
         Int.incr errors;
         eprintf "  [error] hand: %s\n%!" (Exn.to_string exn);
         (* Reset token on error to start fresh *)
         token := None)
    done)
  in
  (match !errors > 0 with
   | true -> eprintf "  [warn] %d/%d hands had errors\n%!" !errors num_hands
   | false -> ());
  (!total_winnings, elapsed)

(* ------------------------------------------------------------------ *)
(* Build concrete hole cards from canonical hand                       *)
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
(* Build showdown distribution trees for all 169 canonical hands       *)
(* ------------------------------------------------------------------ *)

let build_showdown_trees () : Rhode_island.Node_label.t Tree.t array =
  let all_hands = Array.of_list Equity.all_canonical_hands in
  Array.map all_hands ~f:(fun (h : Equity.canonical_hand) ->
    let (h1, h2) = concrete_hole_cards h in
    let dealt = [ h1; h2 ] in
    let rem =
      List.filter Card.full_deck ~f:(fun c ->
        not (List.exists dealt ~f:(fun cc -> Card.equal c cc)))
    in
    let rem_arr = Array.of_list rem in
    let n_rem = Array.length rem_arr in
    (* Build a showdown distribution tree with sampled board+opponent combos *)
    let children =
      List.init 20 ~f:(fun _ ->
        (* Shuffle and pick 5 board + opponents *)
        for i = 0 to Int.min 6 (n_rem - 1) do
          let j = i + Random.int (n_rem - i) in
          let tmp = rem_arr.(i) in
          rem_arr.(i) <- rem_arr.(j);
          rem_arr.(j) <- tmp
        done;
        let n_opps = Int.min 15 ((n_rem - 5) / 2) in
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

(* ------------------------------------------------------------------ *)
(* Build equity-quantile abstraction for a given bucket count          *)
(* ------------------------------------------------------------------ *)

let build_equity_abstraction ~n_buckets ~equities : Abstraction.abstraction_partial =
  let assignments, centroids =
    Abstraction.quantile_bucketing ~n_buckets equities
  in
  { Abstraction.street = Preflop
  ; n_buckets
  ; assignments
  ; centroids
  }

(* ------------------------------------------------------------------ *)
(* Build RBM epsilon-based abstraction from precomputed distance matrix *)
(* ------------------------------------------------------------------ *)

let build_epsilon_abstraction
    ~epsilon
    ~(trees : Rhode_island.Node_label.t Tree.t array)
    ~(dist_matrix : Ev_graph.dist_matrix)
  : Abstraction.abstraction_partial * int =
  let tree_list = Array.to_list trees in
  let graph =
    Ev_graph.compress ~epsilon ~precomputed:dist_matrix tree_list
  in
  let n_clusters = List.length graph.clusters in
  (* Build bucket assignment: for each canonical hand, find its cluster *)
  let assignments = Hashtbl.Poly.create () in
  List.iteri graph.clusters ~f:(fun cluster_idx cluster ->
    List.iter cluster.members ~f:(fun (hand_id, _tree) ->
      Hashtbl.set assignments ~key:hand_id ~data:cluster_idx));
  (* Compute centroids from cluster representative EVs *)
  let centroids = Array.of_list
      (List.map graph.clusters ~f:(fun c -> Tree.ev c.representative))
  in
  let abs : Abstraction.abstraction_partial =
    { street = Preflop
    ; n_buckets = n_clusters
    ; assignments
    ; centroids
    }
  in
  (abs, n_clusters)

(* ------------------------------------------------------------------ *)
(* Fast preflop equities (Monte Carlo)                                 *)
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

(* ------------------------------------------------------------------ *)
(* Result type for one (abstraction, training) cell                    *)
(* ------------------------------------------------------------------ *)

type cell_result = {
  method_name : string;
  bucket_count : int;
  iterations : int;
  info_sets : int;
  train_time : float;
  total_winnings : int;
  num_hands : int;
  play_time : float;
  bb_per_hand : float;
} [@@warning "-69"]

(* ------------------------------------------------------------------ *)
(* Incremental CSV saver                                               *)
(* ------------------------------------------------------------------ *)

let csv_header =
  "method,buckets,iterations,info_sets,train_time_s,total_winnings_chips,num_hands,play_time_s,bb_per_hand"

let cell_to_csv (r : cell_result) =
  sprintf "%s,%d,%d,%d,%.2f,%d,%d,%.2f,%.4f"
    r.method_name r.bucket_count r.iterations r.info_sets r.train_time
    r.total_winnings r.num_hands r.play_time r.bb_per_hand

let append_csv ~filename (r : cell_result) =
  let oc = Out_channel.create ~append:true filename in
  Out_channel.output_string oc (cell_to_csv r ^ "\n");
  Out_channel.close oc

let init_csv ~filename =
  let oc = Out_channel.create filename in
  Out_channel.output_string oc (csv_header ^ "\n");
  Out_channel.close oc

(* ------------------------------------------------------------------ *)
(* Train + play for one (abstraction, iteration_count) pair            *)
(* ------------------------------------------------------------------ *)

let run_cell
    ~(mode : api_mode)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(iterations : int)
    ~(num_hands : int)
    ~(method_name : string)
    ~(csv_file : string)
  : cell_result =
  (* Train *)
  let report_every =
    match iterations >= 100_000 with
    | true -> 50_000
    | false -> Int.max 1_000 (iterations / 5)
  in
  let ((p0, p1), train_time) = time (fun () ->
    Cfr_nolimit.train_mccfr ~config:slumbot_config ~abstraction
      ~iterations ~report_every ())
  in
  let n_p0 = Hashtbl.length p0 in
  let n_p1 = Hashtbl.length p1 in
  let total_info_sets = n_p0 + n_p1 in
  eprintf "    trained %s iters in %s (%s info sets)\n%!"
    (format_int_with_commas iterations) (format_time_short train_time)
    (format_info_sets total_info_sets);
  (* Save strategy *)
  (try
     let strategy_dir = "results/strategies" in
     Core_unix.mkdir_p strategy_dir;
     let strategy_file = sprintf "%s/strat_surface_%s_%db_%dk.sexp"
         strategy_dir (String.lowercase method_name)
         abstraction.n_buckets (iterations / 1_000) in
     save_strategy ~filename:strategy_file p0 p1
   with _ -> ());
  (* Play *)
  let (total_winnings, play_time) =
    play_session ~mode ~num_hands ~p0_strat:p0 ~p1_strat:p1 ~abstraction
  in
  let bb_per_hand =
    Float.of_int total_winnings
    /. Float.of_int num_hands
    /. Float.of_int slumbot_big_blind
  in
  eprintf "    played %d hands: %+.2f bb/hand (%+d chips in %s)\n%!"
    num_hands bb_per_hand total_winnings (format_time_short play_time);
  let result =
    { method_name
    ; bucket_count = abstraction.n_buckets
    ; iterations
    ; info_sets = total_info_sets
    ; train_time
    ; total_winnings
    ; num_hands
    ; play_time
    ; bb_per_hand
    }
  in
  (* Incremental save *)
  append_csv ~filename:csv_file result;
  result

(* ------------------------------------------------------------------ *)
(* Print the bucket x training surface table                           *)
(* ------------------------------------------------------------------ *)

let print_surface_table
    ~(bucket_counts : int list)
    ~(checkpoints : int list)
    ~(results : cell_result list) =
  printf "\n=== Performance Surface: Buckets x Training ===\n\n";
  (* Header *)
  printf "  %-14s" "";
  List.iter checkpoints ~f:(fun cp ->
    printf "  %-12s"
      (match cp >= 1_000_000 with
       | true -> sprintf "%dM iter" (cp / 1_000_000)
       | false ->
         match cp >= 1_000 with
         | true -> sprintf "%dK iter" (cp / 1_000)
         | false -> sprintf "%d iter" cp));
  printf "\n";
  printf "  %s\n" (String.make (14 + 14 * List.length checkpoints) '-');
  (* Rows *)
  List.iter bucket_counts ~f:(fun nb ->
    printf "  %-14s" (sprintf "%d buckets" nb);
    List.iter checkpoints ~f:(fun cp ->
      let cell = List.find results ~f:(fun r ->
        r.bucket_count = nb && r.iterations = cp)
      in
      match cell with
      | Some r -> printf "  %+-12.2f" r.bb_per_hand
      | None -> printf "  %-12s" "---");
    printf "\n");
  printf "\n"

(* ------------------------------------------------------------------ *)
(* Print the epsilon clustering table                                  *)
(* ------------------------------------------------------------------ *)

let print_epsilon_table
    ~(epsilon_checkpoints : int list)
    ~(results : (float * int * cell_result list) list) =
  printf "\n=== Epsilon-Based Clustering (RBM Distance Threshold) ===\n\n";
  printf "  %-10s  %-10s" "epsilon" "clusters";
  List.iter epsilon_checkpoints ~f:(fun cp ->
    printf "  %-12s"
      (match cp >= 1_000_000 with
       | true -> sprintf "%dM iter" (cp / 1_000_000)
       | false ->
         match cp >= 1_000 with
         | true -> sprintf "%dK iter" (cp / 1_000)
         | false -> sprintf "%d iter" cp));
  printf "\n";
  printf "  %s\n" (String.make (22 + 14 * List.length epsilon_checkpoints) '-');
  List.iter results ~f:(fun (eps, n_clusters, cells) ->
    printf "  %-10.2f  %-10d" eps n_clusters;
    List.iter epsilon_checkpoints ~f:(fun cp ->
      let cell = List.find cells ~f:(fun r -> r.iterations = cp) in
      match cell with
      | Some r -> printf "  %+-12.2f" r.bb_per_hand
      | None -> printf "  %-12s" "---");
    printf "\n");
  printf "\n"

(* ------------------------------------------------------------------ *)
(* Entry point                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let buckets_str = ref "5,10,20,50,100,169" in
  let checkpoints_str = ref "10000,50000,100000,500000,1000000" in
  let epsilons_str = ref "0.01,0.05,0.1,0.2,0.5,1.0" in
  let epsilon_checkpoints_str = ref "100000,500000,1000000" in
  let num_hands = ref 100 in
  let mock = ref false in
  let eq_mc_samples = ref 5_000 in
  let skip_epsilon = ref false in

  let args = [
    ("--buckets", Arg.Set_string buckets_str,
     "N,N,...  Comma-separated bucket counts (default: 5,10,20,50,100,169)");
    ("--checkpoints", Arg.Set_string checkpoints_str,
     "N,N,...  Comma-separated MCCFR iteration counts (default: 10000,50000,100000,500000,1000000)");
    ("--epsilons", Arg.Set_string epsilons_str,
     "F,F,...  Comma-separated epsilon thresholds (default: 0.01,0.05,0.1,0.2,0.5,1.0)");
    ("--epsilon-checkpoints", Arg.Set_string epsilon_checkpoints_str,
     "N,N,...  MCCFR iterations for epsilon sweep (default: 100000,500000,1000000)");
    ("--hands", Arg.Set_int num_hands,
     "N  Hands to play per cell (default: 100)");
    ("--mock", Arg.Set mock,
     "  Use local mock Slumbot (check/call bot)");
    ("--eq-mc-samples", Arg.Set_int eq_mc_samples,
     "N  MC samples for equity estimation (default: 5000)");
    ("--skip-epsilon", Arg.Set skip_epsilon,
     "  Skip epsilon-based clustering sweep");
  ] in
  Arg.parse args (fun _ -> ())
    "rbm-surface-sweep [--buckets N,...] [--checkpoints N,...] [--hands N] [--mock]";

  let bucket_counts =
    String.split !buckets_str ~on:','
    |> List.map ~f:(fun s -> Int.of_string (String.strip s))
    |> List.sort ~compare:Int.compare
  in
  let checkpoints =
    String.split !checkpoints_str ~on:','
    |> List.map ~f:(fun s -> Int.of_string (String.strip s))
    |> List.sort ~compare:Int.compare
  in
  let epsilons =
    String.split !epsilons_str ~on:','
    |> List.map ~f:(fun s -> Float.of_string (String.strip s))
    |> List.sort ~compare:Float.compare
  in
  let epsilon_checkpoints =
    String.split !epsilon_checkpoints_str ~on:','
    |> List.map ~f:(fun s -> Int.of_string (String.strip s))
    |> List.sort ~compare:Int.compare
  in

  let mode =
    match !mock with
    | true -> Mock
    | false -> Real
  in
  let mode_str =
    match mode with
    | Real -> "LIVE (slumbot.com)"
    | Mock -> "MOCK (local check/call bot)"
  in

  let t_start = Core_unix.gettimeofday () in

  let total_bucket_cells = List.length bucket_counts * List.length checkpoints in
  let total_epsilon_cells =
    match !skip_epsilon with
    | true -> 0
    | false -> List.length epsilons * List.length epsilon_checkpoints
  in

  printf "================================================================\n";
  printf "  Surface Sweep: Buckets x Training x Epsilon\n";
  printf "================================================================\n\n";
  printf "  Mode:               %s\n" mode_str;
  printf "  Bucket counts:      [%s]\n"
    (String.concat ~sep:", " (List.map bucket_counts ~f:Int.to_string));
  printf "  Training levels:    [%s]\n"
    (String.concat ~sep:", " (List.map checkpoints ~f:format_int_with_commas));
  printf "  Hands per cell:     %d\n" !num_hands;
  printf "  Bucket sweep cells: %d\n" total_bucket_cells;
  (match !skip_epsilon with
   | true -> printf "  Epsilon sweep:      SKIPPED\n"
   | false ->
     printf "  Epsilons:           [%s]\n"
       (String.concat ~sep:", " (List.map epsilons ~f:(sprintf "%.2f")));
     printf "  Epsilon train lvls: [%s]\n"
       (String.concat ~sep:", " (List.map epsilon_checkpoints ~f:format_int_with_commas));
     printf "  Epsilon cells:      %d\n" total_epsilon_cells);
  printf "  Total cells:        %d\n" (total_bucket_cells + total_epsilon_cells);
  printf "  Game:               HUNL 50/100 blinds, 20000 stack (200bb)\n";
  printf "\n%!";

  (* Initialize CSV *)
  Core_unix.mkdir_p "results";
  let csv_file = "results/surface_sweep.csv" in
  init_csv ~filename:csv_file;
  eprintf "[csv] Writing incremental results to %s\n%!" csv_file;

  (* ================================================================ *)
  (* Part 1: Compute preflop equities (once, shared by all buckets)   *)
  (* ================================================================ *)

  printf "[1/3] Computing preflop equities (%s MC samples per hand)...\n%!"
    (format_int_with_commas !eq_mc_samples);
  let (equities, eq_time) = time (fun () ->
    fast_preflop_equities ~n_samples:!eq_mc_samples)
  in
  printf "  Equities computed in %s (169 canonical hands)\n\n%!" (format_time_short eq_time);

  (* ================================================================ *)
  (* Part 2: Bucket sweep                                              *)
  (* ================================================================ *)

  printf "[2/3] Running bucket sweep: %d bucket_counts x %d training_levels = %d cells\n%!"
    (List.length bucket_counts) (List.length checkpoints) total_bucket_cells;

  (* Build all abstractions first *)
  let bucket_abstractions = List.map bucket_counts ~f:(fun nb ->
    eprintf "  Building %d-bucket abstraction...\n%!" nb;
    let (abs, abs_time) = time (fun () ->
      build_equity_abstraction ~n_buckets:nb ~equities)
    in
    eprintf "  %d-bucket abstraction built in %s\n%!" nb (format_time_short abs_time);
    (nb, abs))
  in
  printf "\n";

  let cell_num = ref 0 in
  let bucket_results = ref [] in
  List.iter bucket_abstractions ~f:(fun (nb, abs) ->
    eprintf "--- %d buckets ---\n%!" nb;
    List.iter checkpoints ~f:(fun iters ->
      Int.incr cell_num;
      eprintf "  [cell %d/%d] %d buckets, %s iterations\n%!"
        !cell_num total_bucket_cells nb (format_int_with_commas iters);
      let result =
        run_cell ~mode ~abstraction:abs ~iterations:iters
          ~num_hands:!num_hands ~method_name:"equity" ~csv_file
      in
      bucket_results := result :: !bucket_results));
  let bucket_results = List.rev !bucket_results in

  (* ================================================================ *)
  (* Part 3: Epsilon sweep (RBM clustering)                            *)
  (* ================================================================ *)

  let epsilon_results =
    match !skip_epsilon with
    | true ->
      printf "\n[3/3] Epsilon sweep: SKIPPED (--skip-epsilon)\n%!";
      []
    | false ->
      printf "\n[3/3] Running epsilon sweep: %d epsilons x %d training_levels = %d cells\n%!"
        (List.length epsilons) (List.length epsilon_checkpoints) total_epsilon_cells;

      (* Build showdown distribution trees *)
      eprintf "  Building showdown distribution trees for 169 hands...\n%!";
      let (trees, tree_time) = time build_showdown_trees in
      eprintf "  Trees built in %s\n%!" (format_time_short tree_time);

      (* Compute pairwise RBM distance matrix *)
      eprintf "  Computing pairwise RBM distance matrix (169x169)...\n%!";
      let max_epsilon = List.fold epsilons ~init:0.0 ~f:Float.max in
      let ((dist_matrix, (ev_pruned, shallow_pruned, full_computed)), dist_time) =
        time (fun () ->
          Ev_graph.precompute_distances_fast ~threshold:max_epsilon
            (Array.to_list trees))
      in
      eprintf "  Distance matrix computed in %s (ev_pruned=%d shallow=%d full=%d)\n%!"
        (format_time_short dist_time) ev_pruned shallow_pruned full_computed;

      (* For each epsilon, build abstraction and sweep training levels *)
      let eps_cell_num = ref 0 in
      let all_epsilon_results = List.map epsilons ~f:(fun eps ->
        eprintf "\n--- epsilon=%.2f ---\n%!" eps;
        let (abs, n_clusters) =
          build_epsilon_abstraction ~epsilon:eps ~trees ~dist_matrix
        in
        eprintf "  epsilon=%.2f -> %d clusters\n%!" eps n_clusters;
        let cells = List.map epsilon_checkpoints ~f:(fun iters ->
          Int.incr eps_cell_num;
          eprintf "  [eps-cell %d/%d] eps=%.2f (%d clusters), %s iterations\n%!"
            !eps_cell_num total_epsilon_cells eps n_clusters
            (format_int_with_commas iters);
          run_cell ~mode ~abstraction:abs ~iterations:iters
            ~num_hands:!num_hands
            ~method_name:(sprintf "rbm_eps%.2f" eps)
            ~csv_file)
        in
        (eps, n_clusters, cells))
      in
      all_epsilon_results
  in

  (* ================================================================ *)
  (* Print final results                                               *)
  (* ================================================================ *)

  let t_end = Core_unix.gettimeofday () in
  let total_time = t_end -. t_start in

  printf "\n";
  printf "================================================================\n";
  printf "  SURFACE SWEEP RESULTS\n";
  printf "================================================================\n";

  print_surface_table ~bucket_counts ~checkpoints ~results:bucket_results;

  (match List.length epsilon_results > 0 with
   | true ->
     print_epsilon_table ~epsilon_checkpoints ~results:epsilon_results
   | false -> ());

  (* Summary statistics *)
  printf "=== Summary ===\n\n";
  printf "  Total wall time:    %s\n" (format_time_short total_time);
  printf "  Equity computation: %s\n" (format_time_short eq_time);
  printf "  Cells completed:    %d/%d\n"
    (List.length bucket_results
     + List.sum (module Int) epsilon_results ~f:(fun (_, _, cells) -> List.length cells))
    (total_bucket_cells + total_epsilon_cells);

  (* Find best bucket configuration *)
  (match List.length bucket_results > 0 with
   | true ->
     let best_bucket = List.fold bucket_results
         ~init:(List.hd_exn bucket_results)
         ~f:(fun best r ->
           match Float.( > ) r.bb_per_hand best.bb_per_hand with
           | true -> r
           | false -> best)
     in
     printf "  Best bucket config: %d buckets, %s iterations -> %+.2f bb/hand\n"
       best_bucket.bucket_count
       (format_int_with_commas best_bucket.iterations)
       best_bucket.bb_per_hand
   | false -> ());

  (* Find best epsilon configuration *)
  (match List.length epsilon_results > 0 with
   | true ->
     let all_eps_cells = List.concat_map epsilon_results
         ~f:(fun (_, _, cells) -> cells) in
     (match List.length all_eps_cells > 0 with
      | true ->
        let best_eps = List.fold all_eps_cells
            ~init:(List.hd_exn all_eps_cells)
            ~f:(fun best r ->
              match Float.( > ) r.bb_per_hand best.bb_per_hand with
              | true -> r
              | false -> best)
        in
        printf "  Best epsilon config: %s, %s iterations -> %+.2f bb/hand\n"
          best_eps.method_name
          (format_int_with_commas best_eps.iterations)
          best_eps.bb_per_hand
      | false -> ())
   | false -> ());

  printf "\n  Results saved to: %s\n" csv_file;
  printf "================================================================\n%!"
