(** No-Limit Hold'em game tree generator with multi-player support.

    Variable bet sizes (pot fractions + all-in) and N-player betting
    rounds.  Reuses {!Hand_eval7} for showdown evaluation and the
    {!Tree} type for game tree representation.

    Design: the game tree is built recursively per betting round, with
    a round_state tracking all N players' stacks, investments, and
    fold/all-in status.  At each decision node, available actions are
    fold, check/call, each configured pot fraction bet, and all-in. *)

(* ------------------------------------------------------------------ *)
(* Actions                                                             *)
(* ------------------------------------------------------------------ *)

module Action = struct
  type t =
    | Fold
    | Check
    | Call
    | Bet_frac of float
    | All_in
  [@@deriving sexp, compare, equal]

  let to_string = function
    | Fold -> "fold"
    | Check -> "check"
    | Call -> "call"
    | Bet_frac f -> sprintf "bet_%.0f%%" (f *. 100.0)
    | All_in -> "all_in"

  let to_history_char = function
    | Fold -> "f"
    | Check -> "k"
    | Call -> "c"
    | Bet_frac f ->
      (match Float.( = ) f 0.25 with
       | true -> "q"  (* quarter pot *)
       | false ->
         match Float.( = ) f 0.33 with
         | true -> "t"  (* third pot *)
         | false ->
           match Float.( = ) f 0.5 with
           | true -> "h"  (* half pot *)
           | false ->
             match Float.( = ) f 0.75 with
             | true -> "r"  (* three-quarter pot *)
             | false ->
               match Float.( = ) f 1.0 with
               | true -> "p"  (* pot *)
               | false ->
                 match Float.( = ) f 1.5 with
                 | true -> "o"  (* overbet *)
                 | false ->
                   match Float.( = ) f 2.0 with
                   | true -> "d"  (* double pot *)
                   | false -> sprintf "b%.0f" (f *. 100.0))
    | All_in -> "a"
end

(* ------------------------------------------------------------------ *)
(* Node labels                                                         *)
(* ------------------------------------------------------------------ *)

module Node_label = struct
  type t =
    | Root
    | Chance of { description : string }
    | Decision of { player : int; actions_available : Action.t list }
    | Terminal of { winners : int list; pot : int }
  [@@deriving sexp]
end

(* ------------------------------------------------------------------ *)
(* Player state                                                        *)
(* ------------------------------------------------------------------ *)

type player_state = {
  cards : Card.t * Card.t;
  stack : int;
  folded : bool;
  all_in : bool;
  invested : int;
}

(* ------------------------------------------------------------------ *)
(* Config                                                              *)
(* ------------------------------------------------------------------ *)

type config = {
  deck : Card.t list;
  small_blind : int;
  big_blind : int;
  starting_stack : int;
  bet_fractions : float list;
  max_raises_per_round : int;
  num_players : int;
}

let standard_config =
  { deck = Card.full_deck
  ; small_blind = 1
  ; big_blind = 2
  ; starting_stack = 400  (* 200 big blinds *)
  ; bet_fractions = [ 0.5; 1.0; 2.0 ]
  ; max_raises_per_round = 4
  ; num_players = 2
  }

let short_stack_config =
  { deck = Card.full_deck
  ; small_blind = 1
  ; big_blind = 2
  ; starting_stack = 40  (* 20 big blinds *)
  ; bet_fractions = [ 0.5; 1.0 ]
  ; max_raises_per_round = 4
  ; num_players = 2
  }

let six_max_short_config =
  { deck = Card.full_deck
  ; small_blind = 1
  ; big_blind = 2
  ; starting_stack = 40
  ; bet_fractions = [ 0.5; 1.0 ]
  ; max_raises_per_round = 4
  ; num_players = 6
  }

let expanded_config =
  { deck = Card.full_deck
  ; small_blind = 1
  ; big_blind = 2
  ; starting_stack = 400  (* 200 big blinds *)
  ; bet_fractions = [ 0.25; 0.33; 0.5; 0.75; 1.0; 1.5; 2.0 ]
  ; max_raises_per_round = 4
  ; num_players = 2
  }

(* ------------------------------------------------------------------ *)
(* Betting round state for N players                                   *)
(* ------------------------------------------------------------------ *)

type round_state = {
  players : player_state array;
  to_act : int;
  current_bet : int;       (** highest per-round bet any player has made *)
  num_raises : int;
  last_raiser : int;       (** seat of last raiser, for action-closes detection *)
  round_idx : int;
  num_players : int;
  (** Number of players who still need to act before the round closes.
      Resets whenever someone raises; the round ends when this hits 0. *)
  actions_remaining : int;
}

(* ------------------------------------------------------------------ *)
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

(** Total pot across all players. *)
let total_pot (players : player_state array) : int =
  Array.fold players ~init:0 ~f:(fun acc p -> acc + p.invested)

(** Number of players still in the hand (not folded). *)
let active_count (players : player_state array) : int =
  Array.count players ~f:(fun p -> not p.folded)

(** Number of players still able to act (not folded, not all-in). *)
let can_act_count (players : player_state array) : int =
  Array.count players ~f:(fun p -> not p.folded && not p.all_in)

(** Next seat that can act (not folded, not all-in), wrapping around.
    Returns None if no one can act. *)
let next_active_seat (players : player_state array) ~(from : int) ~(n : int) : int option =
  let rec loop count =
    match count >= n with
    | true -> None
    | false ->
      let seat = (from + 1 + count) % n in
      match not players.(seat).folded && not players.(seat).all_in with
      | true -> Some seat
      | false -> loop (count + 1)
  in
  loop 0

(** Evaluate showdown: return list of winning player indices (ties possible).
    Only considers non-folded players. *)
let evaluate_showdown (players : player_state array) ~(board : Card.t list) : int list =
  let active =
    Array.to_list (Array.filter_mapi players ~f:(fun i p ->
      match p.folded with
      | true -> None
      | false -> Some (i, p.cards)))
  in
  match active with
  | [] -> []
  | [ (i, _) ] -> [ i ]
  | _ ->
    (* Evaluate each active player's hand *)
    let evaluated =
      List.map active ~f:(fun (i, (c1, c2)) ->
        let hand = [ c1; c2 ] @ board in
        let eval = Hand_eval7.evaluate7 hand in
        (i, eval))
    in
    (* Find the best hand *)
    let best_eval =
      List.fold evaluated ~init:(snd (List.hd_exn evaluated))
        ~f:(fun best (_, eval) ->
          match Hand_eval7.compare_evaluated eval best > 0 with
          | true -> eval
          | false -> best)
    in
    (* All players that tie with the best *)
    List.filter_map evaluated ~f:(fun (i, eval) ->
      match Hand_eval7.compare_evaluated eval best_eval = 0 with
      | true -> Some i
      | false -> None)

(** Terminal node: one player wins because all others folded. *)
let fold_terminal ~(winner : int) ~(pot : int) ~(players : player_state array) : Node_label.t Tree.t =
  (* Value from player 0's perspective: positive if p0 wins, negative if p0 loses *)
  let p0_invested = players.(0).invested in
  let value =
    match winner = 0 with
    | true -> Float.of_int (pot - p0_invested)
    | false -> Float.of_int (-p0_invested)
  in
  Tree.leaf ~label:(Node_label.Terminal { winners = [ winner ]; pot }) ~value

(** Terminal node: showdown. *)
let showdown_terminal ~(players : player_state array) ~(board : Card.t list) : Node_label.t Tree.t =
  let pot = total_pot players in
  let winners = evaluate_showdown players ~board in
  let n_winners = List.length winners in
  let share = pot / (Int.max 1 n_winners) in
  let p0_invested = players.(0).invested in
  let value =
    match List.mem winners 0 ~equal:Int.equal with
    | true -> Float.of_int (share - p0_invested)
    | false -> Float.of_int (-p0_invested)
  in
  Tree.leaf ~label:(Node_label.Terminal { winners; pot }) ~value

(** How much a player must add to match the current bet this round.
    A player's per-round investment is tracked via the difference between
    their total invested and what they had invested at the start of the round.
    For simplicity, current_bet tracks the max any single player has put in
    this round relative to the round start, and we track each player's
    round contribution. *)
let amount_to_call (p : player_state) ~(current_bet : int) ~(round_start_invested : int array) ~(seat : int) : int =
  let already_in_round = p.invested - round_start_invested.(seat) in
  let needed = current_bet - already_in_round in
  Int.min needed p.stack

(* ------------------------------------------------------------------ *)
(* Core betting round recursion                                        *)
(* ------------------------------------------------------------------ *)

(** Build available actions for a player at a decision point.
    Returns [(action, resulting_player_state, new_current_bet, is_raise)] *)
let available_actions ~(config : config) ~(players : player_state array)
    ~(seat : int) ~(current_bet : int) ~(num_raises : int)
    ~(round_start_invested : int array)
  : (Action.t * player_state * int * bool) list =
  let p = players.(seat) in
  let to_call = amount_to_call p ~current_bet ~round_start_invested ~seat in
  let facing_bet = to_call > 0 in
  let pot = total_pot players in
  let can_raise = num_raises < config.max_raises_per_round && p.stack > to_call in
  let actions = ref [] in
  (* Fold: only available when facing a bet *)
  (match facing_bet with
   | true ->
     let folded_p = { p with folded = true } in
     actions := (Action.Fold, folded_p, current_bet, false) :: !actions
   | false -> ());
  (* Check (no bet) or Call (match bet) *)
  let check_call_p = { p with
    stack = p.stack - to_call;
    invested = p.invested + to_call;
  } in
  let check_call_action =
    match facing_bet with
    | true -> Action.Call
    | false -> Action.Check
  in
  actions := (check_call_action, check_call_p, current_bet, false) :: !actions;
  (* Bet fractions (only if we can raise) *)
  (match can_raise with
   | true ->
     let pot_after_call = pot + to_call in
     List.iter config.bet_fractions ~f:(fun frac ->
       let raise_amount = Int.max 1 (Float.to_int (Float.of_int pot_after_call *. frac)) in
       let total_to_put_in = to_call + raise_amount in
       match total_to_put_in < p.stack with
       | true ->
         let new_p = { p with
           stack = p.stack - total_to_put_in;
           invested = p.invested + total_to_put_in;
         } in
         let in_round = p.invested + total_to_put_in - round_start_invested.(seat) in
         actions := (Action.Bet_frac frac, new_p, in_round, true) :: !actions
       | false -> ());
     (* All-in *)
     let all_in_amount = p.stack in
     (match all_in_amount > to_call with
      | true ->
        let new_p = { p with
          stack = 0;
          invested = p.invested + all_in_amount;
          all_in = true;
        } in
        let in_round = p.invested + all_in_amount - round_start_invested.(seat) in
        actions := (Action.All_in, new_p, in_round, true) :: !actions
      | false ->
        (* All-in just to call *)
        match all_in_amount > 0 && all_in_amount = to_call with
        | true -> ()  (* Already covered by call *)
        | false -> ())
   | false ->
     (* Can't raise, but might be forced all-in to call *)
     match p.stack > 0 && p.stack < to_call with
     | true ->
       (* All-in call: put in remaining stack *)
       let new_p = { p with
         stack = 0;
         invested = p.invested + p.stack;
         all_in = true;
       } in
       actions := (Action.All_in, new_p, current_bet, false) :: !actions
     | false -> ());
  List.rev !actions

(** Advance to the next betting round or showdown. *)
let rec advance_to_next_round ~(config : config) ~(players : player_state array)
    ~(board : Card.t list) ~(round_idx : int) : Node_label.t Tree.t =
  let next_round = round_idx + 1 in
  match next_round >= 4 with
  | true ->
    showdown_terminal ~players ~board
  | false ->
    (* Only one active player? They win. *)
    (match active_count players = 1 with
     | true ->
       let winner =
         Array.findi_exn players ~f:(fun _ p -> not p.folded) |> fst
       in
       fold_terminal ~winner ~pot:(total_pot players) ~players
     | false ->
       (* No one can act (everyone all-in or folded except one)? Showdown. *)
       match can_act_count players <= 1 with
       | true -> showdown_terminal ~players ~board
       | false ->
         (* Post-flop: action starts left of the dealer.
            In heads-up, SB=0 acts first post-flop.
            In multi-way, SB=0 acts first post-flop. *)
         let round_start_invested = Array.map players ~f:(fun p -> p.invested) in
         let first_seat =
           match next_active_seat players ~from:(config.num_players - 1) ~n:config.num_players with
           | Some s -> s
           | None -> 0
         in
         let n_can_act = can_act_count players in
         let state = {
           players;
           to_act = first_seat;
           current_bet = 0;
           num_raises = 0;
           last_raiser = -1;
           round_idx = next_round;
           num_players = config.num_players;
           actions_remaining = n_can_act;
         } in
         betting_round ~config ~board ~state ~round_start_invested)

(** Main betting round recursion. *)
and betting_round ~(config : config) ~(board : Card.t list) ~(state : round_state)
    ~(round_start_invested : int array)
  : Node_label.t Tree.t =
  let { players; to_act; current_bet; num_raises; round_idx; num_players; actions_remaining; _ } = state in

  (* Round is over when everyone has acted *)
  match actions_remaining <= 0 with
  | true ->
    advance_to_next_round ~config ~players ~board ~round_idx
  | false ->
    (* Only one non-folded player left? *)
    match active_count players = 1 with
    | true ->
      let winner =
        Array.findi_exn players ~f:(fun _ p -> not p.folded) |> fst
      in
      fold_terminal ~winner ~pot:(total_pot players) ~players
    | false ->
      (* Current player already folded or all-in? Skip. *)
      match players.(to_act).folded || players.(to_act).all_in with
      | true ->
        let next_seat =
          match next_active_seat players ~from:to_act ~n:num_players with
          | Some s -> s
          | None ->
            (* No one else can act — end round *)
            (to_act + 1) % num_players
        in
        betting_round ~config ~board
          ~state:{ state with to_act = next_seat; actions_remaining = actions_remaining - 1 }
          ~round_start_invested
      | false ->
        let actions =
          available_actions ~config ~players ~seat:to_act
            ~current_bet ~num_raises ~round_start_invested
        in
        let action_labels = List.map actions ~f:(fun (a, _, _, _) -> a) in
        let children =
          List.map actions ~f:(fun (_, new_p, new_bet, is_raise) ->
            let new_players = Array.copy players in
            new_players.(to_act) <- new_p;
            let new_num_raises =
              match is_raise with
              | true -> num_raises + 1
              | false -> num_raises
            in
            (* If this is a raise, everyone else needs to act again *)
            let new_actions_remaining =
              match is_raise with
              | true -> can_act_count new_players - 1  (* everyone except raiser *)
              | false -> actions_remaining - 1
            in
            (* Handle fold: if only one player left, terminal *)
            match new_p.folded && active_count new_players = 1 with
            | true ->
              let winner =
                Array.findi_exn new_players ~f:(fun _ p -> not p.folded) |> fst
              in
              fold_terminal ~winner ~pot:(total_pot new_players) ~players:new_players
            | false ->
              let next_seat =
                match next_active_seat new_players ~from:to_act ~n:num_players with
                | Some s -> s
                | None -> (to_act + 1) % num_players
              in
              let new_current_bet =
                match is_raise with
                | true -> new_bet
                | false -> current_bet
              in
              (* If no one can act anymore, end the round *)
              match new_actions_remaining <= 0 || can_act_count new_players = 0 with
              | true ->
                advance_to_next_round ~config ~players:new_players ~board ~round_idx
              | false ->
                betting_round ~config ~board
                  ~state:{
                    players = new_players;
                    to_act = next_seat;
                    current_bet = new_current_bet;
                    num_raises = new_num_raises;
                    last_raiser = (match is_raise with true -> to_act | false -> state.last_raiser);
                    round_idx;
                    num_players;
                    actions_remaining = new_actions_remaining;
                  }
                  ~round_start_invested)
        in
        Tree.node
          ~label:(Node_label.Decision { player = to_act; actions_available = action_labels })
          ~children

(* ------------------------------------------------------------------ *)
(* N-player entry point                                                *)
(* ------------------------------------------------------------------ *)

let game_tree_for_deal_n ~(config : config) ~(players : player_state array)
    ~(board : Card.t list) : Node_label.t Tree.t =
  let n = Array.length players in
  let round_start_invested = Array.map players ~f:(fun p -> p.invested) in
  (* Preflop: BB is the current bet.  Action starts with the player after BB.
     In heads-up, that's SB (seat 0).
     In multi-way, that's UTG (seat 2). *)
  let current_bet = config.big_blind in
  let first_to_act =
    match n = 2 with
    | true -> 0  (* heads-up: SB acts first preflop *)
    | false ->
      (* Multi-way: first active seat after BB (seat 1) *)
      match next_active_seat players ~from:1 ~n with
      | Some s -> s
      | None -> 0
  in
  let n_can_act = can_act_count players in
  let state = {
    players;
    to_act = first_to_act;
    current_bet;
    num_raises = 1;  (* BB counts as the opening bet *)
    last_raiser = 1; (* BB is the initial "raiser" *)
    round_idx = 0;
    num_players = n;
    actions_remaining = n_can_act;  (* everyone gets to act *)
  } in
  betting_round ~config ~board ~state ~round_start_invested

(* ------------------------------------------------------------------ *)
(* Heads-up entry point                                                *)
(* ------------------------------------------------------------------ *)

let game_tree_for_deal ~(config : config) ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t) ~(board : Card.t list) : Node_label.t Tree.t =
  let players = [|
    { cards = p1_cards
    ; stack = config.starting_stack - config.small_blind
    ; folded = false
    ; all_in = false
    ; invested = config.small_blind
    };
    { cards = p2_cards
    ; stack = config.starting_stack - config.big_blind
    ; folded = false
    ; all_in = false
    ; invested = config.big_blind
    };
  |] in
  game_tree_for_deal_n ~config ~players ~board

(* ------------------------------------------------------------------ *)
(* Showdown distribution tree (for RBM bucketing)                      *)
(* ------------------------------------------------------------------ *)

(** Build a compact showdown distribution tree for a hand at a given
    board state.  Samples board completions and opponent hands to create
    a small tree (~max_board_samples * max_opponents nodes) capturing
    the hand's strength distribution.

    This is the NL equivalent of {!Limit_holdem.showdown_distribution_tree}.
    The tree structure is identical — only the node label type differs
    ([Node_label.t] uses [winners] list instead of [winner] option).
    Since {!Distance.compute} is polymorphic in label type, these trees
    work directly with the RBM distance metric. *)
let showdown_distribution_tree ?(max_opponents = 15) ?(max_board_samples = 5)
    ~config:_ ~player ~hole_cards ~board_visible () =
  let (h1, h2) = hole_cards in
  let dealt = [ h1; h2 ] @ board_visible in
  let remaining =
    List.filter Card.full_deck ~f:(fun c ->
      not (List.exists dealt ~f:(fun cc -> Card.equal c cc)))
  in
  let n_board_needed = 5 - List.length board_visible in
  let remaining_arr = Array.of_list remaining in
  let n_rem = Array.length remaining_arr in
  let children = ref [] in
  let n_boards_sampled = ref 0 in
  while !n_boards_sampled < max_board_samples do
    (* Sample board completion via Fisher-Yates partial shuffle *)
    for i = 0 to Int.min (n_board_needed + 2 - 1) (n_rem - 1) do
      let j = i + Random.int (n_rem - i) in
      let tmp = remaining_arr.(i) in
      remaining_arr.(i) <- remaining_arr.(j);
      remaining_arr.(j) <- tmp
    done;
    let extra_board =
      match n_board_needed with
      | 0 -> []
      | k -> List.init (Int.min k n_rem) ~f:(fun i -> remaining_arr.(i))
    in
    let full_board = board_visible @ extra_board in
    (* Sample opponents from remaining cards after board *)
    let opp_start = n_board_needed in
    let n_opp_available = (n_rem - opp_start) / 2 in
    let n_opps = Int.min max_opponents n_opp_available in
    (* Partial shuffle for opponents *)
    for i = opp_start to Int.min (opp_start + n_opps * 2 - 1) (n_rem - 1) do
      let j = i + Random.int (n_rem - i) in
      let tmp = remaining_arr.(i) in
      remaining_arr.(i) <- remaining_arr.(j);
      remaining_arr.(j) <- tmp
    done;
    let opp_leaves = ref [] in
    for k = 0 to n_opps - 1 do
      let o1 = remaining_arr.(opp_start + k * 2) in
      let o2 = remaining_arr.(opp_start + k * 2 + 1) in
      let p1h = [ h1; h2 ] @ full_board in
      let p2h = [ o1; o2 ] @ full_board in
      let cmp = Hand_eval7.compare_hands7 p1h p2h in
      let value =
        match player with
        | 0 ->
          (match cmp > 0 with true -> 1.0 | false ->
           match cmp = 0 with true -> 0.0 | false -> -1.0)
        | _ ->
          (match cmp > 0 with true -> -1.0 | false ->
           match cmp = 0 with true -> 0.0 | false -> 1.0)
      in
      opp_leaves :=
        Tree.leaf ~label:(Node_label.Terminal { winners = []; pot = 0 })
          ~value
        :: !opp_leaves
    done;
    children :=
      Tree.node
        ~label:(Node_label.Chance { description = "board_sample" })
        ~children:(List.rev !opp_leaves)
      :: !children;
    Int.incr n_boards_sampled
  done;
  Tree.node
    ~label:(Node_label.Chance {
      description = sprintf "showdown_dist p%d" (player + 1)
    })
    ~children:(List.rev !children)
