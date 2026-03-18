(** Slumbot API client for heads-up no-limit Hold'em.

    Plays against Slumbot (https://slumbot.com) using a trained NL MCCFR
    strategy.  Communicates via Slumbot's REST API (JSON over HTTPS).

    Slumbot game parameters:
    - Blinds: 50/100
    - Stack: 20,000 chips (200 BB)
    - Heads-up no-limit Hold'em

    API endpoints (base: https://slumbot.com):
    - POST /slumbot/api/login      -- authenticate (optional)
    - POST /slumbot/api/new_hand   -- start a new hand
    - POST /slumbot/api/act        -- take an action

    Action encoding:
    - "k"      = check
    - "c"      = call
    - "f"      = fold
    - "b{N}"   = bet/raise to N chips (street-relative)

    Card encoding: standard ACPC format (e.g., "Ac" = Ace of clubs).

    client_pos: 0 = big blind (acts second preflop, first postflop),
                1 = small blind (acts first preflop, second postflop).

    Usage:
      opam exec -- dune exec -- rbm-slumbot-client --train 50000
      opam exec -- dune exec -- rbm-slumbot-client --strategy strat_nl.bin --hands 200
      opam exec -- dune exec -- rbm-slumbot-client --mock --hands 50 --verbose *)

open Rbm

(* ------------------------------------------------------------------ *)
(* Constants matching Slumbot's game                                   *)
(* ------------------------------------------------------------------ *)

let slumbot_small_blind = 50
let slumbot_big_blind = 100
let slumbot_stack = 20_000

(** NL config matching Slumbot's game parameters. *)
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
(* Strategy serialization                                              *)
(* ------------------------------------------------------------------ *)

let strategy_to_sexp (strat : Compact_cfr.strategy) : Sexp.t =
  let entries =
    Hashtbl.fold strat ~init:[] ~f:(fun ~key ~data acc ->
      let probs = List.map (Array.to_list data) ~f:(fun f ->
        Sexp.Atom (Float.to_string f)) in
      Sexp.List [ Sexp.Atom key; Sexp.List probs ] :: acc)
  in
  Sexp.List entries

let strategy_of_sexp (sexp : Sexp.t) : Compact_cfr.strategy =
  let table = Hashtbl.create (module String) in
  (match sexp with
   | Sexp.List entries ->
     List.iter entries ~f:(fun entry ->
       match entry with
       | Sexp.List [ Sexp.Atom key; Sexp.List probs ] ->
         let arr = Array.of_list
           (List.map probs ~f:(fun p ->
              match p with
              | Sexp.Atom s -> Float.of_string s
              | _ -> failwith "strategy_of_sexp: expected float")) in
         Hashtbl.set table ~key ~data:arr
       | _ -> failwith "strategy_of_sexp: malformed entry")
   | _ -> failwith "strategy_of_sexp: expected list");
  table

let save_strategy ~filename (p0 : Compact_cfr.strategy) (p1 : Compact_cfr.strategy) =
  let sexp = Sexp.List [ strategy_to_sexp p0; strategy_to_sexp p1 ] in
  Out_channel.write_all filename ~data:(Sexp.to_string sexp)

let load_strategy ~filename : Compact_cfr.strategy * Compact_cfr.strategy =
  let sexp = Sexp.load_sexp filename in
  match sexp with
  | Sexp.List [ p0_sexp; p1_sexp ] ->
    (strategy_of_sexp p0_sexp, strategy_of_sexp p1_sexp)
  | _ -> failwith "load_strategy: expected pair of tables"

(* ------------------------------------------------------------------ *)
(* Card parsing (Slumbot uses ACPC format: "Ac", "Td", etc.)          *)
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
(* Slumbot action string parsing                                       *)
(* ------------------------------------------------------------------ *)

(** Parse Slumbot's action string to determine game state.

    Actions: k=check, c=call, f=fold, b{N}=bet to N chips on this street.
    Streets separated by '/'.

    Returns: (street, position_to_act, street_last_bet_to, total_last_bet_to,
              last_bet_size, is_hand_over) *)
type action_state = {
  street : int;
  pos : int;             (** -1 = hand over *)
  street_last_bet_to : int;
  total_last_bet_to : int;
  last_bet_size : int;
  last_bettor : int;     (** -1 = no bettor *)
} [@@warning "-69"]

let parse_slumbot_action (action : string) : action_state =
  let st = ref 0 in
  let street_last_bet_to = ref slumbot_big_blind in
  let total_last_bet_to = ref slumbot_big_blind in
  let last_bet_size = ref (slumbot_big_blind - slumbot_small_blind) in
  let last_bettor = ref 0 in
  let pos = ref 1 in  (* SB acts first preflop *)
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
         (* Call of all-in -- skip remaining street slashes *)
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
      i := sz  (* fold ends hand *)
    | 'b' ->
      (* Parse bet size *)
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
      (* Explicit street separator (can appear in all-in runouts) *)
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

(** Determine if it's our turn to act based on the parsed action state and
    our position. *)
let is_our_turn (state : action_state) ~(client_pos : int) : bool =
  state.pos >= 0 && state.pos = client_pos

(* ------------------------------------------------------------------ *)
(* Convert Slumbot action history to internal NL history format        *)
(* ------------------------------------------------------------------ *)

(** Convert Slumbot action string to the internal history format used by
    Cfr_nolimit for info-set key construction.

    Slumbot: k=check, c=call, f=fold, b{N}=bet/raise to N
    Internal: k=check, c=call, f=fold, h/p/d/a=bet fractions

    Since Slumbot's bet sizes are continuous and ours are bucketed
    (0.5x, 1.0x, 2.0x pot), we map each Slumbot bet to the nearest
    fraction category.  This is an approximation. *)
let slumbot_action_to_internal_history (action : string) : string =
  let buf = Buffer.create (String.length action) in
  let i = ref 0 in
  let sz = String.length action in
  let street_pot = ref (slumbot_small_blind + slumbot_big_blind) in
  let street_invested = [| ref slumbot_small_blind; ref slumbot_big_blind |] in
  let cur_pos = ref 1 in  (* SB acts first preflop *)
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
      (* Map to nearest fraction bucket or all-in *)
      let total_after = !(street_invested.(!cur_pos)) + new_street_bet in
      let _ = total_after in
      let hist_char =
        match Float.( >= ) frac 1.5 with
        | true ->
          (match new_street_bet >= slumbot_stack with
           | true -> 'a'
           | false -> 'd')  (* 2x pot *)
        | false ->
          match Float.( >= ) frac 0.75 with
          | true -> 'p'    (* 1x pot *)
          | false -> 'h'   (* 0.5x pot *)
      in
      Buffer.add_char buf hist_char;
      street_invested.(!cur_pos) := new_street_bet;
      street_pot := !street_pot + raise_amount;
      cur_pos := (!cur_pos + 1) mod 2
    | '/' ->
      Buffer.add_char buf '/';
      street_invested.(0) := 0;
      street_invested.(1) := 0;
      cur_pos := 0  (* Post-flop: position 0 (BB) acts first *)
    | _ -> ()
  done;
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Determine current street from action string                         *)
(* ------------------------------------------------------------------ *)

let _street_of_action (action : string) : int =
  String.count action ~f:(fun c -> Char.equal c '/')

(* ------------------------------------------------------------------ *)
(* Action selection using trained NL strategy                          *)
(* ------------------------------------------------------------------ *)

(** Select an action for the current Slumbot game state.

    Maps the Slumbot state to an internal info-set key, looks up the
    strategy, samples an action, then converts back to Slumbot format.

    Returns: (slumbot_action_string, info_key, strategy_probs) *)
let select_slumbot_action
    ~(p0_strat : Compact_cfr.strategy)
    ~(p1_strat : Compact_cfr.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(client_pos : int)
    ~(action : string)
    ~(action_state : action_state)
  : string * string * float array =
  (* Compute buckets *)
  let buckets =
    Compact_cfr.precompute_buckets_equity ~abstraction ~hole_cards ~board
  in
  let round_idx = action_state.street in
  let internal_history = slumbot_action_to_internal_history action in
  let key = Compact_cfr.make_info_key ~buckets ~round_idx ~history:internal_history in
  (* Our position in the trained strategy: client_pos 0 = BB = position 1 in
     internal model (SB=0, BB=1).  Actually Slumbot: client_pos 0 = BB,
     client_pos 1 = SB.  Our internal: position 0 = SB, position 1 = BB.
     So: client_pos 0 (BB) -> use p1_strat, client_pos 1 (SB) -> use p0_strat. *)
  let strategy =
    match client_pos with
    | 1 -> p0_strat  (* SB = position 0 *)
    | _ -> p1_strat  (* BB = position 1 *)
  in
  (* Available actions: fold (if facing bet), check/call, bet fractions, all-in *)
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
  (* Add bet options: map internal fractions to Slumbot bet sizes *)
  let pot = action_state.total_last_bet_to * 2 in  (* approximate *)
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
     (* All-in *)
     (match remaining > 0 with
      | true ->
        let all_in_street_bet = action_state.street_last_bet_to + remaining in
        actions := (sprintf "b%d" all_in_street_bet, "a") :: !actions
      | false -> ())
   | false -> ());
  let actions = List.rev !actions in
  let action_arr = Array.of_list actions in
  let num_actions = Array.length action_arr in
  (* Look up strategy *)
  let probs =
    match Hashtbl.find strategy key with
    | Some p ->
      (match Array.length p = num_actions with
       | true -> p
       | false -> Array.create ~len:num_actions (1.0 /. Float.of_int num_actions))
    | None ->
      Array.create ~len:num_actions (1.0 /. Float.of_int num_actions)
  in
  (* Sample action *)
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
(* HTTP client (via curl subprocess)                                   *)
(* ------------------------------------------------------------------ *)

(** Execute an HTTP POST request using curl and return the JSON response.

    We use curl as a subprocess rather than an OCaml HTTP library to avoid
    adding async dependencies to this binary.  For production use, replace
    with cohttp-async or piaf. *)
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
(* JSON helpers (using Yojson)                                         *)
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
(* Slumbot API client                                                  *)
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

let slumbot_login ~(username : string) ~(password : string) : string =
  let body = sprintf {|{"username": "%s", "password": "%s"}|} username password in
  let url = slumbot_base_url ^ "/login" in
  match http_post ~url ~json_body:body with
  | Error msg -> failwithf "slumbot_login failed: %s" msg ()
  | Ok response ->
    match json_of_string response with
    | Error msg -> failwithf "slumbot_login: bad JSON: %s" msg ()
    | Ok json ->
      match json_string_field json "token" with
      | Some t -> t
      | None -> failwith "slumbot_login: no token in response"

(* ------------------------------------------------------------------ *)
(* Mock Slumbot server (for offline testing)                           *)
(* ------------------------------------------------------------------ *)

(** A mock Slumbot implementation that plays a simple check/call strategy.
    Used when the real API is unavailable or for offline testing. *)
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
    (* If client_pos = 1 (SB), bot is BB and acts second preflop.
       If client_pos = 0 (BB), bot is SB and acts first preflop.
       In Slumbot, the API may include bot's action if bot acts first. *)
    (* Mock bot: always check when first to act *)
    let initial_action =
      match client_pos with
      | 0 ->
        (* Client is BB; bot is SB. SB acts first preflop.
           Bot's action: check (actually in NL preflop SB can only call/raise/fold) *)
        state.action <- "c";  (* Bot calls the BB *)
        "c"
      | _ ->
        (* Client is SB; bot is BB. SB acts first. No bot action yet. *)
        ""
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
    let cmp = Hand_eval7.compare_hands7 client_hand opp_hand in
    cmp

  let act ~(token : string) ~(incr : string) : Yojson.Safe.t =
    let _ = token in
    match !current_hand with
    | None -> failwith "mock: no hand in progress"
    | Some state ->
      state.action <- state.action ^ incr;
      let a_state = parse_slumbot_action state.action in
      let (c1, c2) = state.hole_cards in
      let visible_board = board_for_street state.board a_state.street in
      (* Check if hand is over *)
      match a_state.pos < 0 with
      | true ->
        (* Hand over -- compute winnings *)
        let action = state.action in
        let has_fold = String.is_suffix action ~suffix:"f" in
        let winnings =
          match has_fold with
          | true ->
            (* Determine if the client was the one who folded.
               The simplest check: did the client's last incremental action
               contain 'f'? *)
            let client_folded = String.is_suffix (String.rstrip incr) ~suffix:"f" in
            (match client_folded with
             | true -> - a_state.total_last_bet_to  (* Lost our chips *)
             | false -> a_state.total_last_bet_to)  (* Won opponent's chips *)
          | false ->
            (* Showdown *)
            let cmp = evaluate_winner state in
            (match cmp > 0 with
             | true -> a_state.total_last_bet_to   (* We won *)
             | false ->
               match cmp < 0 with
               | true -> - a_state.total_last_bet_to  (* We lost *)
               | false -> 0)  (* Split *)
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
        (* Bot's turn -- mock bot plays check/call *)
        let bot_pos =
          match state.client_pos with
          | 0 -> 0  (* Client=BB -> bot is pos 0 in action string (SB) *)
          | _ -> 1  (* Client=SB -> bot is pos 1 (BB) *)
        in
        let _ = bot_pos in
        (* Is it the bot's turn? *)
        let our_turn = is_our_turn a_state ~client_pos:state.client_pos in
        (match our_turn with
         | true ->
           (* Still client's turn, return state *)
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
           (* Bot's turn: check or call *)
           let bot_incr =
             match a_state.last_bet_size > 0 with
             | true -> "c"
             | false -> "k"
           in
           state.action <- state.action ^ bot_incr;
           let new_a_state = parse_slumbot_action state.action in
           let new_visible_board = board_for_street state.board new_a_state.street in
           (* Check if hand ended after bot's action *)
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
(* Unified API interface (real or mock)                                *)
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
(* Hand player                                                         *)
(* ------------------------------------------------------------------ *)

(** Play a single hand against Slumbot (or mock).

    Returns (new_token, winnings_in_chips). *)
let play_hand
    ~(mode : api_mode)
    ~(token : string option)
    ~(p0_strat : Compact_cfr.strategy)
    ~(p1_strat : Compact_cfr.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(verbose : bool)
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
  (match verbose with
   | true ->
     let (c1, c2) = hole_cards in
     eprintf "[slumbot] Hand started. pos=%d hole=%s%s\n%!"
       client_pos (Card.to_string c1) (Card.to_string c2)
   | false -> ());
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
    (* Check if hand is over *)
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
      (match verbose with
       | true ->
         eprintf "[slumbot] Hand over. action=%s winnings=%d\n%!" action winnings
       | false -> ());
      (Some token, winnings)
    | false ->
      (* Parse action state *)
      let a_state = parse_slumbot_action action in
      let our_turn = is_our_turn a_state ~client_pos in
      (match our_turn with
       | false ->
         (* Not our turn yet, but API should only return when it's our turn
            or hand is over.  In mock mode we may need to handle this. *)
         (match verbose with
          | true -> eprintf "[slumbot] Not our turn. action=%s\n%!" action
          | false -> ());
         (Some token, 0)
       | true ->
         let (incr, key, probs) =
           select_slumbot_action
             ~p0_strat ~p1_strat ~abstraction
             ~hole_cards ~board ~client_pos ~action ~action_state:a_state
         in
         (match verbose with
          | true ->
            eprintf "[slumbot] action=%s our_incr=%s key=%s probs=[%s]\n%!"
              action incr key
              (String.concat ~sep:"," (Array.to_list
                 (Array.map probs ~f:(sprintf "%.3f"))))
          | false -> ());
         let response = api_act ~mode ~token ~incr in
         let new_tok = json_string_field response "token" in
         let _ = new_tok in
         play_loop response)
  in
  play_loop json

(* ------------------------------------------------------------------ *)
(* Session runner                                                      *)
(* ------------------------------------------------------------------ *)

let run_session
    ~(mode : api_mode)
    ~(num_hands : int)
    ~(p0_strat : Compact_cfr.strategy)
    ~(p1_strat : Compact_cfr.strategy)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(verbose : bool)
    ~(username : string)
    ~(password : string)
  =
  let mode_str =
    match mode with
    | Real -> "LIVE (slumbot.com)"
    | Mock -> "MOCK (local check/call bot)"
  in
  eprintf "[slumbot] Starting session: %s, %d hands\n%!" mode_str num_hands;
  (* Login if credentials provided *)
  let initial_token =
    match mode with
    | Mock -> None
    | Real ->
      match String.length username > 0 && String.length password > 0 with
      | true ->
        eprintf "[slumbot] Logging in as %s...\n%!" username;
        let token = slumbot_login ~username ~password in
        eprintf "[slumbot] Login successful. Token: %s\n%!" token;
        Some token
      | false -> None
  in
  let total_winnings = ref 0 in
  let token = ref initial_token in
  let t_start = Core_unix.gettimeofday () in
  for hand = 1 to num_hands do
    (try
       let (new_token, winnings) =
         play_hand ~mode ~token:!token
           ~p0_strat ~p1_strat ~abstraction ~verbose
       in
       token := new_token;
       total_winnings := !total_winnings + winnings;
       let avg_bb =
         Float.of_int !total_winnings
         /. Float.of_int hand
         /. Float.of_int slumbot_big_blind
       in
       (match hand mod 10 = 0 || verbose with
        | true ->
          eprintf "[slumbot] Hand %d/%d: won=%d total=%d (%.2f mbb/hand)\n%!"
            hand num_hands winnings !total_winnings (avg_bb *. 1000.0)
        | false -> ())
     with exn ->
       eprintf "[slumbot] Error on hand %d: %s\n%!" hand (Exn.to_string exn))
  done;
  let t_end = Core_unix.gettimeofday () in
  let elapsed = t_end -. t_start in
  let avg_bb =
    Float.of_int !total_winnings
    /. Float.of_int num_hands
    /. Float.of_int slumbot_big_blind
  in
  printf "\n";
  printf "================================================================\n";
  printf "  Slumbot Session Results (%s)\n" mode_str;
  printf "================================================================\n";
  printf "\n";
  printf "  Hands played:    %d\n" num_hands;
  printf "  Total winnings:  %d chips\n" !total_winnings;
  printf "  Average:         %.2f mbb/hand\n" (avg_bb *. 1000.0);
  printf "  Average:         %.4f bb/hand\n" avg_bb;
  printf "  Time:            %.1f seconds (%.2f hands/sec)\n"
    elapsed (Float.of_int num_hands /. elapsed);
  printf "\n";
  printf "  Game: HUNL 50/100 blinds, 20000 stack (200bb)\n";
  printf "  Strategy: NL MCCFR, P0=%d P1=%d info sets\n"
    (Hashtbl.length p0_strat) (Hashtbl.length p1_strat);
  printf "================================================================\n"

(* ------------------------------------------------------------------ *)
(* Entry point                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  let train_iters = ref 0 in
  let strategy_file = ref "" in
  let save_file = ref "" in
  let n_buckets = ref 10 in
  let num_hands = ref 100 in
  let mock = ref false in
  let verbose = ref false in
  let username = ref "" in
  let password = ref "" in
  let checkpoint_every = ref 0 in
  let checkpoint_prefix = ref "checkpoint" in
  let resume_file = ref "" in

  let args = [
    ("--train", Arg.Set_int train_iters,
     "N  Train NL MCCFR for N iterations before playing");
    ("--strategy", Arg.Set_string strategy_file,
     "FILE  Load pre-trained NL strategy from FILE");
    ("--save", Arg.Set_string save_file,
     "FILE  Save trained strategy to FILE");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Preflop abstraction buckets (default: 10)");
    ("--hands", Arg.Set_int num_hands,
     "N  Number of hands to play (default: 100)");
    ("--mock", Arg.Set mock,
     "  Use local mock Slumbot (check/call bot) instead of real API");
    ("--verbose", Arg.Set verbose,
     "  Log every action");
    ("--username", Arg.Set_string username,
     "USER  Slumbot username (optional, for tracked sessions)");
    ("--password", Arg.Set_string password,
     "PASS  Slumbot password (optional)");
    ("--checkpoint-every", Arg.Set_int checkpoint_every,
     "N  Save checkpoint every N training iterations (default: 0 = off)");
    ("--checkpoint-prefix", Arg.Set_string checkpoint_prefix,
     "PREFIX  Checkpoint filename prefix (default: checkpoint)");
    ("--resume", Arg.Set_string resume_file,
     "FILE  Resume training from a checkpoint .dat file");
  ] in
  Arg.parse args (fun _ -> ())
    "rbm-slumbot-client [--train N | --strategy FILE] [--hands N] [--mock] [--verbose]";

  (* Build abstraction *)
  eprintf "[slumbot] Building %d-bucket preflop abstraction...\n%!" !n_buckets;
  let (preflop_abs, abs_time) = time (fun () ->
    Abstraction.abstract_preflop_equity ~n_buckets:!n_buckets)
  in
  eprintf "[slumbot] Abstraction built in %.2fs\n%!" abs_time;

  (* Get strategy *)
  let (p0_strat, p1_strat) =
    match String.length !strategy_file > 0 with
    | true ->
      eprintf "[slumbot] Loading NL strategy from %s\n%!" !strategy_file;
      load_strategy ~filename:!strategy_file
    | false ->
      match !train_iters > 0 with
      | true ->
        eprintf "[slumbot] Training NL MCCFR for %d iterations (%d buckets)...\n%!"
          !train_iters !n_buckets;
        let config = slumbot_config in
        let ((p0, p1), train_time) = time (fun () ->
          let resume_from =
            match String.length !resume_file > 0 with
            | true -> Some !resume_file
            | false -> None
          in
          Compact_cfr.train_mccfr ~config ~abstraction:preflop_abs
            ~iterations:!train_iters ~report_every:10_000
            ~checkpoint_every:!checkpoint_every
            ~checkpoint_prefix:!checkpoint_prefix
            ?resume_from ())
        in
        eprintf "[slumbot] Training complete in %.2fs. P0: %d, P1: %d info sets\n%!"
          train_time (Hashtbl.length p0) (Hashtbl.length p1);
        (match String.length !save_file > 0 with
         | true ->
           save_strategy ~filename:!save_file p0 p1;
           eprintf "[slumbot] Strategy saved to %s\n%!" !save_file
         | false -> ());
        (p0, p1)
      | false ->
        eprintf "[slumbot] WARNING: No strategy specified. Using uniform random.\n%!";
        (Hashtbl.create (module String), Hashtbl.create (module String))
  in

  let mode =
    match !mock with
    | true -> Mock
    | false -> Real
  in
  run_session ~mode ~num_hands:!num_hands
    ~p0_strat ~p1_strat ~abstraction:preflop_abs
    ~verbose:!verbose
    ~username:!username ~password:!password
