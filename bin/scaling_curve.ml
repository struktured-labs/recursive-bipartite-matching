(** Scaling curve experiment: measures bot performance vs Slumbot at
    multiple MCCFR training levels to establish diminishing returns.

    Compares two abstraction methods:
    - RBM: showdown distribution tree approach (game-tree-aware)
    - EMD: equity-based quantile bucketing (scalar equity only)

    At each checkpoint, both bots play 100 hands against Slumbot and
    record loss rate in bb/hand.  Results are saved to results/ directory.

    Usage:
      opam exec -- dune exec -- rbm-scaling-curve
      opam exec -- dune exec -- rbm-scaling-curve --mock --hands-per-checkpoint 50
      opam exec -- dune exec -- rbm-scaling-curve --checkpoints 10000,50000,100000 *)

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
(* Strategy serialization (reused from slumbot_client)                 *)
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
(* HTTP client (via curl)                                              *)
(* ------------------------------------------------------------------ *)

let http_post ~(url : string) ~(json_body : string) : (string, string) result =
  let escaped_body = String.concat_map json_body ~f:(fun c ->
    match Char.equal c '\'' with
    | true -> "'\\''"
    | false -> String.of_char c)
  in
  let cmd = sprintf
    "curl -s -X POST '%s' -H 'Content-Type: application/json' -d '%s' 2>&1"
    url escaped_body
  in
  let ic = Core_unix.open_process_in cmd in
  let body = In_channel.input_all ic in
  let status = Core_unix.close_process_in ic in
  match status with
  | Ok () -> Ok body
  | Error _ -> Error (sprintf "curl failed: %s" body)

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
  match http_post ~url ~json_body:body with
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
  match http_post ~url ~json_body:body with
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
(* Play a single hand against Slumbot                                  *)
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
         eprintf "  [error] hand: %s\n%!" (Exn.to_string exn))
    done)
  in
  (match !errors > 0 with
   | true -> eprintf "  [warn] %d/%d hands had errors\n%!" !errors num_hands
   | false -> ());
  (!total_winnings, elapsed)

(* ------------------------------------------------------------------ *)
(* RBM abstraction builder (showdown distribution tree approach)       *)
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

let build_rbm_abstraction ~n_buckets : Abstraction.abstraction_partial =
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
    Abstraction.quantile_bucketing ~n_buckets small_evs
  in
  { Abstraction.street = Preflop
  ; n_buckets
  ; assignments
  ; centroids
  }

(* ------------------------------------------------------------------ *)
(* Fast preflop equity (reused from holdem_compare)                    *)
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

let build_emd_abstraction ~n_buckets ~n_samples : Abstraction.abstraction_partial =
  let equities = fast_preflop_equities ~n_samples in
  let assignments, centroids =
    Abstraction.quantile_bucketing ~n_buckets equities
  in
  { Abstraction.street = Preflop
  ; n_buckets
  ; assignments
  ; centroids
  }

(* ------------------------------------------------------------------ *)
(* Checkpoint result type                                              *)
(* ------------------------------------------------------------------ *)

type checkpoint_result = {
  iterations : int;
  info_sets_p0 : int;
  info_sets_p1 : int;
  train_time : float;
  total_winnings : int;
  num_hands : int;
  play_time : float;
  bb_per_hand : float;
}

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
(* Run the scaling curve for one abstraction method                    *)
(* ------------------------------------------------------------------ *)

let run_scaling_curve
    ~(mode : api_mode)
    ~(checkpoints : int list)
    ~(hands_per_checkpoint : int)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(label : string)
  : checkpoint_result list =
  eprintf "\n[%s] Running scaling curve: %d checkpoints, %d hands each\n%!"
    label (List.length checkpoints) hands_per_checkpoint;
  let config = slumbot_config in
  List.map checkpoints ~f:(fun iters ->
    eprintf "  [%s] Training %s iterations...\n%!" label (format_int_with_commas iters);
    let ((p0, p1), train_time) = time (fun () ->
      Cfr_nolimit.train_mccfr ~config ~abstraction
        ~iterations:iters ~report_every:25_000 ())
    in
    let n_p0 = Hashtbl.length p0 in
    let n_p1 = Hashtbl.length p1 in
    eprintf "  [%s] Trained in %.1fs. P0=%s P1=%s info sets\n%!"
      label train_time (format_info_sets n_p0) (format_info_sets n_p1);
    (* Save strategy *)
    let strategy_dir = "results/strategies" in
    let strategy_file = sprintf "%s/strat_%s_%dk.sexp"
        strategy_dir (String.lowercase label) (iters / 1000) in
    (try
       Core_unix.mkdir_p strategy_dir;
       save_strategy ~filename:strategy_file p0 p1;
       eprintf "  [%s] Strategy saved to %s\n%!" label strategy_file
     with exn ->
       eprintf "  [%s] Warning: could not save strategy: %s\n%!"
         label (Exn.to_string exn));
    (* Play against Slumbot *)
    eprintf "  [%s] Playing %d hands vs Slumbot...\n%!" label hands_per_checkpoint;
    let (total_winnings, play_time) =
      play_session ~mode ~num_hands:hands_per_checkpoint
        ~p0_strat:p0 ~p1_strat:p1 ~abstraction
    in
    let bb_per_hand =
      Float.of_int total_winnings
      /. Float.of_int hands_per_checkpoint
      /. Float.of_int slumbot_big_blind
    in
    eprintf "  [%s] %s iters: %.2f bb/hand (%+d chips in %.1fs)\n%!"
      label (format_int_with_commas iters) bb_per_hand total_winnings play_time;
    { iterations = iters
    ; info_sets_p0 = n_p0
    ; info_sets_p1 = n_p1
    ; train_time
    ; total_winnings
    ; num_hands = hands_per_checkpoint
    ; play_time
    ; bb_per_hand
    })

(* ------------------------------------------------------------------ *)
(* Print scaling curve table                                           *)
(* ------------------------------------------------------------------ *)

let print_scaling_table ~(label : string) (results : checkpoint_result list) =
  printf "\n=== %s Training Scaling Curve vs Slumbot ===\n\n" label;
  printf "  %-12s  %-10s  %-10s  %-18s  %-11s\n"
    "Iterations" "Info Sets" "Train Time" "bb/hand vs Slumbot" "Improvement";
  printf "  %s\n" (String.make 73 '-');
  let baseline_bb = ref None in
  List.iter results ~f:(fun r ->
    let total_is = r.info_sets_p0 + r.info_sets_p1 in
    let improvement =
      match !baseline_bb with
      | None ->
        baseline_bb := Some r.bb_per_hand;
        "baseline"
      | Some base_bb ->
        let base_loss = Float.abs base_bb in
        let cur_loss = Float.abs r.bb_per_hand in
        match Float.( > ) base_loss 0.001 && Float.( > ) cur_loss 0.001 with
        | true -> sprintf "%.1fx" (base_loss /. cur_loss)
        | false -> "---"
    in
    printf "  %-12s  %-10s  %-10s  %+-18.2f  %-11s\n"
      (format_int_with_commas r.iterations)
      (format_info_sets total_is)
      (format_time_short r.train_time)
      r.bb_per_hand
      improvement)

(* ------------------------------------------------------------------ *)
(* Print comparison table                                              *)
(* ------------------------------------------------------------------ *)

let print_comparison_table
    ~(rbm_results : checkpoint_result list)
    ~(emd_results : checkpoint_result list) =
  printf "\n=== RBM vs EMD Abstraction Comparison ===\n\n";
  printf "  %-12s  %-12s  %-12s  %-8s\n"
    "Iterations" "RBM bb/hand" "EMD bb/hand" "Winner";
  printf "  %s\n" (String.make 56 '-');
  let rbm_total_loss = ref 0.0 in
  let emd_total_loss = ref 0.0 in
  let rbm_wins = ref 0 in
  let emd_wins = ref 0 in
  List.iter2_exn rbm_results emd_results ~f:(fun rbm emd ->
    let winner =
      match Float.( > ) rbm.bb_per_hand emd.bb_per_hand with
      | true -> Int.incr rbm_wins; "RBM"
      | false ->
        match Float.( < ) rbm.bb_per_hand emd.bb_per_hand with
        | true -> Int.incr emd_wins; "EMD"
        | false -> "TIE"
    in
    rbm_total_loss := !rbm_total_loss +. rbm.bb_per_hand;
    emd_total_loss := !emd_total_loss +. emd.bb_per_hand;
    printf "  %-12s  %+-12.2f  %+-12.2f  %-8s\n"
      (format_int_with_commas rbm.iterations)
      rbm.bb_per_hand
      emd.bb_per_hand
      winner);
  let n = Float.of_int (List.length rbm_results) in
  printf "  %s\n" (String.make 56 '-');
  printf "  %-12s  %+-12.2f  %+-12.2f  %-8s\n"
    "Average"
    (!rbm_total_loss /. n)
    (!emd_total_loss /. n)
    (match Float.( > ) !rbm_total_loss !emd_total_loss with
     | true -> "RBM"
     | false ->
       match Float.( < ) !rbm_total_loss !emd_total_loss with
       | true -> "EMD"
       | false -> "TIE");
  printf "\n  Score: RBM=%d EMD=%d (of %d checkpoints)\n"
    !rbm_wins !emd_wins (List.length rbm_results)

(* ------------------------------------------------------------------ *)
(* Save results to file                                                *)
(* ------------------------------------------------------------------ *)

let save_results
    ~(rbm_results : checkpoint_result list)
    ~(emd_results : checkpoint_result list)
    ~(rbm_abs_time : float)
    ~(emd_abs_time : float)
    ~(total_time : float)
    ~(n_buckets : int)
    ~(hands_per_checkpoint : int)
    ~(mode : api_mode) =
  let filename = "results/scaling_curve.txt" in
  let oc = Out_channel.create filename in
  let pf fmt = Out_channel.fprintf oc fmt in
  let mode_str =
    match mode with
    | Real -> "LIVE (slumbot.com)"
    | Mock -> "MOCK (local check/call bot)"
  in
  pf "================================================================\n";
  pf "  Scaling Curve Experiment Results\n";
  pf "  Date: %s\n" (Core_unix.strftime (Core_unix.localtime (Core_unix.gettimeofday ()))
                        "%Y-%m-%d %H:%M:%S");
  pf "  Mode: %s\n" mode_str;
  pf "================================================================\n\n";
  pf "Parameters:\n";
  pf "  Buckets: %d\n" n_buckets;
  pf "  Hands per checkpoint: %d\n" hands_per_checkpoint;
  pf "  Game: HUNL 50/100 blinds, 20000 stack (200bb)\n";
  pf "  Bet fractions: 0.5x, 1.0x, 2.0x pot\n";
  pf "  RBM abstraction time: %.2fs\n" rbm_abs_time;
  pf "  EMD abstraction time: %.2fs\n" emd_abs_time;
  pf "  Total wall time: %.1fs\n\n" total_time;
  (* RBM table *)
  pf "=== RBM Training Scaling Curve ===\n\n";
  pf "  %-12s  %-10s  %-10s  %-18s  %-11s\n"
    "Iterations" "Info Sets" "Train Time" "bb/hand" "Improvement";
  pf "  %s\n" (String.make 73 '-');
  let baseline_bb = ref None in
  List.iter rbm_results ~f:(fun r ->
    let total_is = r.info_sets_p0 + r.info_sets_p1 in
    let improvement =
      match !baseline_bb with
      | None -> baseline_bb := Some r.bb_per_hand; "baseline"
      | Some base_bb ->
        let base_loss = Float.abs base_bb in
        let cur_loss = Float.abs r.bb_per_hand in
        match Float.( > ) base_loss 0.001 && Float.( > ) cur_loss 0.001 with
        | true -> sprintf "%.1fx" (base_loss /. cur_loss)
        | false -> "---"
    in
    pf "  %-12s  %-10s  %-10s  %+-18.2f  %-11s\n"
      (format_int_with_commas r.iterations)
      (format_info_sets total_is)
      (format_time_short r.train_time)
      r.bb_per_hand
      improvement);
  pf "\n";
  (* EMD table *)
  baseline_bb := None;
  pf "=== EMD Training Scaling Curve ===\n\n";
  pf "  %-12s  %-10s  %-10s  %-18s  %-11s\n"
    "Iterations" "Info Sets" "Train Time" "bb/hand" "Improvement";
  pf "  %s\n" (String.make 73 '-');
  List.iter emd_results ~f:(fun r ->
    let total_is = r.info_sets_p0 + r.info_sets_p1 in
    let improvement =
      match !baseline_bb with
      | None -> baseline_bb := Some r.bb_per_hand; "baseline"
      | Some base_bb ->
        let base_loss = Float.abs base_bb in
        let cur_loss = Float.abs r.bb_per_hand in
        match Float.( > ) base_loss 0.001 && Float.( > ) cur_loss 0.001 with
        | true -> sprintf "%.1fx" (base_loss /. cur_loss)
        | false -> "---"
    in
    pf "  %-12s  %-10s  %-10s  %+-18.2f  %-11s\n"
      (format_int_with_commas r.iterations)
      (format_info_sets total_is)
      (format_time_short r.train_time)
      r.bb_per_hand
      improvement);
  pf "\n";
  (* Comparison table *)
  pf "=== RBM vs EMD Comparison ===\n\n";
  pf "  %-12s  %-12s  %-12s  %-8s\n"
    "Iterations" "RBM bb/hand" "EMD bb/hand" "Winner";
  pf "  %s\n" (String.make 56 '-');
  List.iter2_exn rbm_results emd_results ~f:(fun rbm emd ->
    let winner =
      match Float.( > ) rbm.bb_per_hand emd.bb_per_hand with
      | true -> "RBM"
      | false ->
        match Float.( < ) rbm.bb_per_hand emd.bb_per_hand with
        | true -> "EMD"
        | false -> "TIE"
    in
    pf "  %-12s  %+-12.2f  %+-12.2f  %-8s\n"
      (format_int_with_commas rbm.iterations)
      rbm.bb_per_hand
      emd.bb_per_hand
      winner);
  pf "\n";
  (* Raw data (machine-readable) *)
  pf "=== Raw Data (CSV) ===\n\n";
  pf "method,iterations,info_sets_p0,info_sets_p1,train_time_s,total_winnings_chips,num_hands,play_time_s,bb_per_hand\n";
  List.iter rbm_results ~f:(fun r ->
    pf "RBM,%d,%d,%d,%.2f,%d,%d,%.2f,%.4f\n"
      r.iterations r.info_sets_p0 r.info_sets_p1 r.train_time
      r.total_winnings r.num_hands r.play_time r.bb_per_hand);
  List.iter emd_results ~f:(fun r ->
    pf "EMD,%d,%d,%d,%.2f,%d,%d,%.2f,%.4f\n"
      r.iterations r.info_sets_p0 r.info_sets_p1 r.train_time
      r.total_winnings r.num_hands r.play_time r.bb_per_hand);
  Out_channel.close oc;
  eprintf "[results] Saved to %s\n%!" filename

(* ------------------------------------------------------------------ *)
(* Entry point                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let checkpoints_str = ref "10000,25000,50000,100000,200000" in
  let hands_per_checkpoint = ref 100 in
  let n_buckets = ref 10 in
  let mock = ref false in
  let eq_mc_samples = ref 2_000 in

  let args = [
    ("--checkpoints", Arg.Set_string checkpoints_str,
     "N,N,...  Comma-separated MCCFR iteration checkpoints (default: 10000,25000,50000,100000,200000)");
    ("--hands-per-checkpoint", Arg.Set_int hands_per_checkpoint,
     "N  Hands to play per checkpoint (default: 100)");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Preflop abstraction buckets (default: 10)");
    ("--mock", Arg.Set mock,
     "  Use local mock Slumbot (check/call bot) instead of real API");
    ("--eq-mc-samples", Arg.Set_int eq_mc_samples,
     "N  MC samples for EMD equity estimation (default: 2000)");
  ] in
  Arg.parse args (fun _ -> ())
    "rbm-scaling-curve [--checkpoints N,N,...] [--hands-per-checkpoint N] [--mock]";

  let checkpoints =
    String.split !checkpoints_str ~on:','
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

  printf "================================================================\n";
  printf "  Scaling Curve Experiment: MCCFR vs Slumbot\n";
  printf "================================================================\n\n";
  printf "  Mode:             %s\n" mode_str;
  printf "  Buckets:          %d\n" !n_buckets;
  printf "  Checkpoints:      %s\n"
    (String.concat ~sep:", " (List.map checkpoints ~f:format_int_with_commas));
  printf "  Hands/checkpoint: %d\n" !hands_per_checkpoint;
  printf "  Game:             HUNL 50/100 blinds, 20000 stack (200bb)\n";
  printf "  Bet fractions:    0.5x, 1.0x, 2.0x pot\n";
  printf "  Abstractions:     RBM (showdown tree) vs EMD (equity quantile)\n";
  printf "\n%!";

  (* ================================================================ *)
  (* Build abstractions (once, reused across all checkpoints)         *)
  (* ================================================================ *)

  printf "[1/4] Building %d-bucket RBM abstraction (showdown distribution trees)...\n%!"
    !n_buckets;
  let (rbm_abs, rbm_abs_time) = time (fun () ->
    build_rbm_abstraction ~n_buckets:!n_buckets)
  in
  printf "  RBM abstraction built in %.2fs\n%!" rbm_abs_time;

  printf "[2/4] Building %d-bucket EMD abstraction (equity quantile)...\n%!"
    !n_buckets;
  let (emd_abs, emd_abs_time) = time (fun () ->
    build_emd_abstraction ~n_buckets:!n_buckets ~n_samples:!eq_mc_samples)
  in
  printf "  EMD abstraction built in %.2fs\n\n%!" emd_abs_time;

  (* Show bucket assignments for key hands *)
  printf "  Bucket assignments for key hands:\n";
  printf "  %-6s  %-5s  %-5s\n" "Hand" "RBM" "EMD";
  printf "  %s\n" (String.make 20 '-');
  let key_hands = [
    ("AA", Card.Rank.Ace, Card.Rank.Ace, false);
    ("KK", King, King, false);
    ("AKs", Ace, King, true);
    ("QJs", Queen, Jack, true);
    ("TT", Ten, Ten, false);
    ("55", Five, Five, false);
    ("72o", Seven, Two, false);
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
    printf "  %-6s  %-5d  %-5d\n" name rbm_b emd_b);
  printf "\n%!";

  (* ================================================================ *)
  (* Run scaling curves                                                *)
  (* ================================================================ *)

  printf "[3/4] Running RBM scaling curve...\n%!";
  let rbm_results =
    run_scaling_curve ~mode ~checkpoints
      ~hands_per_checkpoint:!hands_per_checkpoint
      ~abstraction:rbm_abs ~label:"RBM"
  in

  printf "\n[4/4] Running EMD scaling curve...\n%!";
  let emd_results =
    run_scaling_curve ~mode ~checkpoints
      ~hands_per_checkpoint:!hands_per_checkpoint
      ~abstraction:emd_abs ~label:"EMD"
  in

  (* ================================================================ *)
  (* Print results                                                     *)
  (* ================================================================ *)

  let t_end = Core_unix.gettimeofday () in
  let total_time = t_end -. t_start in

  printf "\n================================================================\n";
  printf "  FINAL RESULTS\n";
  printf "================================================================\n";

  print_scaling_table ~label:"RBM" rbm_results;
  print_scaling_table ~label:"EMD" emd_results;
  print_comparison_table ~rbm_results ~emd_results;

  printf "\n  Total wall time: %.1fs\n" total_time;
  printf "  Abstraction overhead: RBM=%.1fs EMD=%.1fs\n"
    rbm_abs_time emd_abs_time;
  printf "\n================================================================\n%!";

  (* Save to file *)
  Core_unix.mkdir_p "results";
  save_results ~rbm_results ~emd_results
    ~rbm_abs_time ~emd_abs_time ~total_time
    ~n_buckets:!n_buckets
    ~hands_per_checkpoint:!hands_per_checkpoint
    ~mode
