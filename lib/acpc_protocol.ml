(** ACPC (Annual Computer Poker Competition) protocol parser for Limit Hold'em.

    Parses MATCHSTATE messages and selects actions using trained strategies. *)

(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type matchstate = {
  position : int;
  hand_number : int;
  betting : string;
  hole_cards : Card.t * Card.t;
  board : Card.t list;
  current_street : int;
  is_our_turn : bool;
}

(* ------------------------------------------------------------------ *)
(* Card parsing                                                        *)
(* ------------------------------------------------------------------ *)

let parse_rank c =
  match c with
  | '2' -> Card.Rank.Two
  | '3' -> Card.Rank.Three
  | '4' -> Card.Rank.Four
  | '5' -> Card.Rank.Five
  | '6' -> Card.Rank.Six
  | '7' -> Card.Rank.Seven
  | '8' -> Card.Rank.Eight
  | '9' -> Card.Rank.Nine
  | 'T' -> Card.Rank.Ten
  | 'J' -> Card.Rank.Jack
  | 'Q' -> Card.Rank.Queen
  | 'K' -> Card.Rank.King
  | 'A' -> Card.Rank.Ace
  | _ -> failwithf "parse_rank: unknown rank char '%c'" c ()

let parse_suit c =
  match c with
  | 'c' -> Card.Suit.Clubs
  | 'd' -> Card.Suit.Diamonds
  | 'h' -> Card.Suit.Hearts
  | 's' -> Card.Suit.Spades
  | _ -> failwithf "parse_suit: unknown suit char '%c'" c ()

let parse_card s =
  match String.length s = 2 with
  | true ->
    let rank = parse_rank (String.get s 0) in
    let suit = parse_suit (String.get s 1) in
    { Card.rank; suit }
  | false -> failwithf "parse_card: expected 2 chars, got %d in %S"
               (String.length s) s ()

(** Parse a sequence of cards from a string like "AhKd9s8h2c".
    Each card is exactly 2 characters. *)
let parse_cards_string s =
  let n = String.length s in
  match n mod 2 = 0 with
  | false -> failwithf "parse_cards_string: odd length %d in %S" n s ()
  | true ->
    let num_cards = n / 2 in
    List.init num_cards ~f:(fun i ->
      parse_card (String.sub s ~pos:(i * 2) ~len:2))

(* ------------------------------------------------------------------ *)
(* Betting history parsing                                             *)
(* ------------------------------------------------------------------ *)

(** Count the number of streets (0-indexed) from the betting string. *)
let current_street_of_betting betting =
  String.count betting ~f:(fun c -> Char.equal c '/')

(** Determine whose turn it is based on the current street's actions. *)
let whose_turn_in_street ~street:_ actions_in_street =
  let n_actions = String.length actions_in_street in
  n_actions mod 2

(** Parse the betting string to determine the acting player. *)
let acting_player_from_betting betting =
  let streets = String.split betting ~on:'/' in
  let street_idx = List.length streets - 1 in
  let current_street_actions = List.last_exn streets in
  whose_turn_in_street ~street:street_idx current_street_actions

(** Determine whether a hand is terminal. *)
let is_terminal betting =
  match String.length betting with
  | 0 -> false
  | _ ->
    let streets = String.split betting ~on:'/' in
    let last_street = List.last_exn streets in
    (* Terminal if last action is fold *)
    let has_fold =
      String.length last_street > 0
      && Char.equal (String.get last_street (String.length last_street - 1)) 'f'
    in
    match has_fold with
    | true -> true
    | false ->
      let n_streets = List.length streets in
      match n_streets > 4 with
      | true -> true
      | false ->
        match n_streets = 4 with
        | false -> false
        | true ->
          let river_actions = List.last_exn streets in
          let n = String.length river_actions in
          match n >= 2 with
          | false -> false
          | true ->
            let last = String.get river_actions (n - 1) in
            let second_last = String.get river_actions (n - 2) in
            Char.equal last 'c'
            && (Char.equal second_last 'c' || Char.equal second_last 'r')

(* ------------------------------------------------------------------ *)
(* Matchstate parsing                                                  *)
(* ------------------------------------------------------------------ *)

let parse_matchstate line =
  let line = String.rstrip line in
  (* Format: MATCHSTATE:position:hand_number:betting:cards
     Note: betting can be empty, so we split with a limit of 5 *)
  let parts = String.split line ~on:':' in
  (* We expect at least 5 parts. If there are more (e.g. due to empty betting),
     rejoin from the 4th field onward to handle edge cases. *)
  let prefix, pos_s, hand_s, betting, cards_s =
    match parts with
    | prefix :: pos_s :: hand_s :: rest ->
      (* rest = [betting; cards_s] or more if cards contain colons (shouldn't happen).
         The betting field is always the 4th, cards the 5th. *)
      (match List.length rest >= 2 with
       | true ->
         let betting = List.nth_exn rest 0 in
         let cards_s = String.concat ~sep:":" (List.tl_exn rest) in
         (prefix, pos_s, hand_s, betting, cards_s)
       | false ->
         failwithf "parse_matchstate: not enough fields in %S" line ())
    | _ ->
      failwithf "parse_matchstate: not enough fields in %S" line ()
  in
  match String.equal prefix "MATCHSTATE" with
  | false -> failwithf "parse_matchstate: expected MATCHSTATE prefix, got %S" prefix ()
  | true ->
    let position = Int.of_string pos_s in
    let hand_number = Int.of_string hand_s in
    (* Parse cards: split by '|' to get [hole; flop; turn; river] segments.
       ACPC card format: {p0_hole}{p1_hole}|{flop3}|{turn1}|{river1}
       Hidden cards are omitted (0 chars). So:
       - Position 0, preflop: "AhKd" (our 4 chars, opponent hidden)
       - Position 1, preflop: "AhKd" (opponent hidden, our 4 chars)
       - Both visible (showdown): "AhKd9s8h" (8 chars = 4+4)
       For simplicity: if hole section is 4 chars, those are our cards.
       If 8 chars, position 0 gets first 4, position 1 gets last 4. *)
    let card_segments = String.split cards_s ~on:'|' in
    let hole_segment, board_segments =
      match card_segments with
      | [] -> failwith "parse_matchstate: no card segments"
      | hole :: rest ->
        let len = String.length hole in
        let our_hole_str =
          match len with
          | 0 -> failwithf "parse_matchstate: empty hole card section in %S" line ()
          | 4 -> hole  (* Just our cards visible *)
          | n when n >= 8 ->
            (* Both players' cards visible *)
            (match position with
             | 0 -> String.sub hole ~pos:0 ~len:4
             | _ -> String.sub hole ~pos:4 ~len:4)
          | _ -> failwithf "parse_matchstate: unexpected hole length %d in %S" len line ()
        in
        (our_hole_str, rest)
    in
    let hole_cards =
      let cards = parse_cards_string hole_segment in
      match cards with
      | [ c1; c2 ] -> (c1, c2)
      | _ -> failwithf "parse_matchstate: expected 2 hole cards, got %d"
               (List.length cards) ()
    in
    let board =
      List.concat_map board_segments ~f:(fun seg ->
        match String.length seg > 0 with
        | true -> parse_cards_string seg
        | false -> [])
    in
    let current_street = current_street_of_betting betting in
    let acting = acting_player_from_betting betting in
    let terminal = is_terminal betting in
    let is_our_turn = (not terminal) && acting = position in
    { position; hand_number; betting; hole_cards; board;
      current_street; is_our_turn }

(* ------------------------------------------------------------------ *)
(* Action formatting                                                   *)
(* ------------------------------------------------------------------ *)

let format_action = function
  | `Fold -> "f"
  | `Call -> "c"
  | `Raise -> "r"

(* ------------------------------------------------------------------ *)
(* Valid actions                                                        *)
(* ------------------------------------------------------------------ *)

let valid_actions (state : matchstate) =
  let streets = String.split state.betting ~on:'/' in
  let current_actions = List.last_exn streets in
  let max_raises = 4 in
  let n_raises = String.count current_actions ~f:(fun c -> Char.equal c 'r') in
  let bet_outstanding =
    match String.length current_actions with
    | 0 ->
      (match state.current_street with
       | 0 -> true    (* Preflop: BB's blind is an implicit bet *)
       | _ -> false)  (* Post-flop: no bet at start *)
    | _ ->
      let last_char = String.get current_actions (String.length current_actions - 1) in
      Char.equal last_char 'r'
  in
  match bet_outstanding with
  | true ->
    (match n_raises < max_raises with
     | true -> [ `Fold; `Call; `Raise ]
     | false -> [ `Fold; `Call ])
  | false ->
    (match n_raises < max_raises with
     | true -> [ `Call; `Raise ]  (* 'c' = check, 'r' = bet *)
     | false -> [ `Call ])        (* 'c' = check only *)

(* ------------------------------------------------------------------ *)
(* ACPC to internal history conversion                                 *)
(* ------------------------------------------------------------------ *)

let acpc_to_internal_history betting =
  let buf = Buffer.create (String.length betting) in
  let streets = String.split betting ~on:'/' in
  List.iteri streets ~f:(fun street_idx street_actions ->
    (match street_idx > 0 with
     | true -> Buffer.add_char buf '/'
     | false -> ());
    let bet_out = ref (match street_idx with 0 -> true | _ -> false) in
    String.iter street_actions ~f:(fun ch ->
      match ch with
      | 'f' -> Buffer.add_char buf 'f'
      | 'c' ->
        (match !bet_out with
         | true ->
           Buffer.add_char buf 'c';
           bet_out := false
         | false ->
           Buffer.add_char buf 'k')
      | 'r' ->
        (match !bet_out with
         | true ->
           Buffer.add_char buf 'r'
         | false ->
           Buffer.add_char buf 'b';
           bet_out := true)
      | _ -> ()));
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Information set key construction                                    *)
(* ------------------------------------------------------------------ *)

let info_key_of_matchstate
    ~(matchstate : matchstate)
    ~(abstraction : Abstraction.abstraction)
  =
  let bucket =
    let canonical = Equity.to_canonical matchstate.hole_cards in
    match Hashtbl.find abstraction.bucket_map
            (sprintf "preflop:%s" canonical.name) with
    | Some b -> b
    | None -> 0
  in
  let internal_history = acpc_to_internal_history matchstate.betting in
  sprintf "%d:%d|%s" matchstate.current_street bucket internal_history

(* ------------------------------------------------------------------ *)
(* Action selection                                                    *)
(* ------------------------------------------------------------------ *)

let choose_action ~matchstate ~strategy ~abstraction =
  let key = info_key_of_matchstate ~matchstate ~abstraction in
  let actions = valid_actions matchstate in
  let n_actions = List.length actions in
  let probs =
    match Hashtbl.find strategy key with
    | Some p ->
      (match Array.length p = n_actions with
       | true -> p
       | false -> Array.create ~len:n_actions (1.0 /. Float.of_int n_actions))
    | None ->
      Array.create ~len:n_actions (1.0 /. Float.of_int n_actions)
  in
  let r = Random.float 1.0 in
  let cumulative = ref 0.0 in
  let chosen = ref (List.last_exn actions) in
  let found = ref false in
  List.iteri actions ~f:(fun i action ->
    match !found with
    | true -> ()
    | false ->
      cumulative := !cumulative +. probs.(i);
      match Float.( >= ) !cumulative r with
      | true -> chosen := action; found := true
      | false -> ());
  !chosen
