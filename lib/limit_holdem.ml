(** Full Limit Hold'em game tree generator.

    4 betting rounds (preflop, flop, turn, river) with blind structure.
    Showdown uses Hand_eval7 (best 5 of 7 cards). *)

module Action = Rhode_island.Action
module Node_label = Rhode_island.Node_label

type config = {
  deck : Card.t list;
  small_blind : int;
  big_blind : int;
  small_bet : int;
  big_bet : int;
  max_raises : int;
}

let standard_config =
  { deck = Card.full_deck
  ; small_blind = 1
  ; big_blind = 2
  ; small_bet = 2
  ; big_bet = 4
  ; max_raises = 4
  }

let remove_cards deck cards =
  List.filter deck ~f:(fun c ->
    not (List.exists cards ~f:(fun cc -> Card.equal c cc)))

let all_pairs cards =
  let arr = Array.of_list cards in
  let n = Array.length arr in
  let pairs = ref [] in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      pairs := (arr.(i), arr.(j)) :: !pairs
    done
  done;
  List.rev !pairs

(** Betting round state.

    Round indices: 0=preflop, 1=flop, 2=turn, 3=river.

    Preflop special handling:
    - SB (player 0) acts first
    - BB's big blind counts as an opening bet
    - First action for SB is: fold, call (match BB), or raise

    Post-flop (rounds 1-3):
    - Player 0 (SB / non-dealer) acts first
    - Standard check/bet opening *)
type round_state = {
  to_act : int;
  num_raises : int;
  bet_outstanding : bool;
  first_checked : bool;
  p1_invested : int;
  p2_invested : int;
  round_idx : int;
}

let bet_size_for_round config round_idx =
  match round_idx with
  | 0 | 1 -> config.small_bet
  | _ -> config.big_bet

let add_to_invested state player amount =
  match player with
  | 0 -> { state with p1_invested = state.p1_invested + amount }
  | _ -> { state with p2_invested = state.p2_invested + amount }

let showdown_value ~p1_cards ~p2_cards ~board ~pot =
  let (p1a, p1b) = p1_cards in
  let (p2a, p2b) = p2_cards in
  let hand1 = [ p1a; p1b ] @ board in
  let hand2 = [ p2a; p2b ] @ board in
  let cmp = Hand_eval7.compare_hands7 hand1 hand2 in
  let winner =
    match cmp > 0 with
    | true -> Some 0
    | false ->
      match cmp < 0 with
      | true -> Some 1
      | false -> None
  in
  Tree.leaf
    ~label:(Node_label.Terminal { winner; pot })
    ~value:(match winner with
      | Some 0 -> Float.of_int (pot / 2)
      | Some _ -> Float.of_int (-(pot / 2))
      | None -> 0.0)

let fold_value ~folder ~pot =
  let winner = match folder with 0 -> 1 | _ -> 0 in
  let value =
    match folder with
    | 0 -> Float.of_int (-(pot / 2))
    | _ -> Float.of_int (pot / 2)
  in
  Tree.leaf ~label:(Node_label.Terminal { winner = Some winner; pot }) ~value

let rec advance_to_next_round ~config ~p1_cards ~p2_cards ~board ~state =
  let next_round = state.round_idx + 1 in
  match next_round >= 4 with
  | true ->
    let pot = state.p1_invested + state.p2_invested in
    showdown_value ~p1_cards ~p2_cards ~board ~pot
  | false ->
    (* Post-flop: player 0 (SB) acts first *)
    let new_state = {
      state with
      to_act = 0;
      num_raises = 0;
      bet_outstanding = false;
      first_checked = false;
      round_idx = next_round;
    } in
    betting_round ~config ~p1_cards ~p2_cards ~board ~state:new_state

and betting_round ~config ~p1_cards ~p2_cards ~board ~state
    : Node_label.t Tree.t =
  let player = state.to_act in
  let bet_sz = bet_size_for_round config state.round_idx in
  let pot = state.p1_invested + state.p2_invested in

  match state.bet_outstanding with
  | true ->
    (* Facing a bet/raise: fold, call, or raise *)
    let fold_child = fold_value ~folder:player ~pot in
    let call_state =
      add_to_invested { state with bet_outstanding = false } player bet_sz
    in
    let call_child =
      advance_to_next_round ~config ~p1_cards ~p2_cards ~board ~state:call_state
    in
    let can_raise = state.num_raises < config.max_raises in
    let actions, children =
      match can_raise with
      | true ->
        let raise_state =
          add_to_invested
            { state with
              to_act = 1 - player;
              num_raises = state.num_raises + 1;
              bet_outstanding = true;
            }
            player (2 * bet_sz)
        in
        let raise_child =
          betting_round ~config ~p1_cards ~p2_cards ~board ~state:raise_state
        in
        ([ Action.Fold; Call; Raise ], [ fold_child; call_child; raise_child ])
      | false ->
        ([ Action.Fold; Call ], [ fold_child; call_child ])
    in
    Tree.node
      ~label:(Node_label.Decision { player; actions_available = actions })
      ~children

  | false ->
    (* No bet outstanding: check or bet *)
    let check_ends_round = state.first_checked in
    let check_child =
      match check_ends_round with
      | true ->
        advance_to_next_round ~config ~p1_cards ~p2_cards ~board ~state
      | false ->
        betting_round ~config ~p1_cards ~p2_cards ~board
          ~state:{ state with to_act = 1 - player; first_checked = true }
    in
    let can_bet = state.num_raises < config.max_raises in
    let actions, children =
      match can_bet with
      | true ->
        let bet_state =
          add_to_invested
            { state with
              to_act = 1 - player;
              num_raises = state.num_raises + 1;
              bet_outstanding = true;
              first_checked = false;
            }
            player bet_sz
        in
        let bet_child =
          betting_round ~config ~p1_cards ~p2_cards ~board ~state:bet_state
        in
        ([ Action.Check; Bet ], [ check_child; bet_child ])
      | false ->
        ([ Action.Check ], [ check_child ])
    in
    Tree.node
      ~label:(Node_label.Decision { player; actions_available = actions })
      ~children

let game_tree_for_deal ~config ~p1_cards ~p2_cards ~board =
  (* Preflop: SB (player 0) posts small blind, BB (player 1) posts big blind.
     BB's post counts as an opening bet.  SB acts first facing a bet. *)
  let state = {
    to_act = 0;
    num_raises = 1;  (* BB's big blind counts as the first raise/bet *)
    bet_outstanding = true;
    first_checked = false;
    p1_invested = config.small_blind;
    p2_invested = config.big_blind;
    round_idx = 0;
  } in
  betting_round ~config ~p1_cards ~p2_cards ~board ~state

(** Build a game tree starting from a specific betting round.

    Unlike [game_tree_for_deal] which always starts from preflop,
    this starts at [round_idx] with [pot_so_far] already invested.
    [board] must contain exactly 5 community cards for showdown evaluation.

    This is used by [information_set_tree] to build subtrees from
    post-flop streets. *)
let game_tree_from_street ~config ~p1_cards ~p2_cards ~board
    ~(round_idx : int) ~(pot_so_far : int) =
  let half_pot = pot_so_far / 2 in
  let state = {
    to_act = 0;
    num_raises = 0;
    bet_outstanding = false;
    first_checked = false;
    p1_invested = half_pot;
    p2_invested = pot_so_far - half_pot;
    round_idx;
  } in
  betting_round ~config ~p1_cards ~p2_cards ~board ~state

(** Build an information set tree for [player] at a given street.

    Aggregates over all possible opponent hole-card pairs AND remaining
    board cards from the remaining deck.

    [hole_cards] is the player's hand.
    [board_visible] is the visible board cards so far (3 for flop, 4 for
    turn, 5 for river).
    [round_idx] is the current street (1=flop, 2=turn, 3=river).
    [pot_so_far] is the total chips invested before this street.

    For flop/turn, samples remaining board cards to complete the 5-card
    board.  For each (opponent_hand, board_completion) pair, generates a
    game subtree from [round_idx] onward.

    To keep tree size manageable, we sample a subset of opponent hands
    when the combination count exceeds [max_opponents] (default 50). *)
let information_set_tree ?(max_opponents = 50) ~config ~player ~hole_cards
    ~board_visible ~round_idx ~pot_so_far () =
  let (h1, h2) = hole_cards in
  let dealt = [ h1; h2 ] @ board_visible in
  let remaining = remove_cards config.deck dealt in
  let n_board_needed = 5 - List.length board_visible in
  (* Generate all possible board completions *)
  let board_completions =
    match n_board_needed with
    | 0 -> [ [] ]
    | 1 ->
      List.map remaining ~f:(fun c -> [ c ])
    | 2 ->
      let arr = Array.of_list remaining in
      let n = Array.length arr in
      let pairs = ref [] in
      for i = 0 to n - 2 do
        for j = i + 1 to n - 1 do
          pairs := [ arr.(i); arr.(j) ] :: !pairs
        done
      done;
      List.rev !pairs
    | _ -> [ [] ]  (* shouldn't happen *)
  in
  (* For each board completion, generate opponent-aggregated subtrees *)
  let children =
    List.concat_map board_completions ~f:(fun extra_board ->
      let full_board = board_visible @ extra_board in
      let remaining_after_board = remove_cards remaining extra_board in
      let all_opps = all_pairs remaining_after_board in
      (* Subsample opponent hands if too many *)
      let opponent_hands =
        match List.length all_opps > max_opponents with
        | true ->
          let arr = Array.of_list all_opps in
          let n = Array.length arr in
          (* Fisher-Yates partial shuffle for first max_opponents *)
          for i = 0 to Int.min (max_opponents - 1) (n - 1) do
            let j = i + Random.int (n - i) in
            let tmp = arr.(i) in
            arr.(i) <- arr.(j);
            arr.(j) <- tmp
          done;
          Array.to_list (Array.sub arr ~pos:0 ~len:(Int.min max_opponents n))
        | false -> all_opps
      in
      List.map opponent_hands ~f:(fun (opp1, opp2) ->
        let p1_cards, p2_cards =
          match player with
          | 0 -> (hole_cards, (opp1, opp2))
          | _ -> ((opp1, opp2), hole_cards)
        in
        let subtree =
          game_tree_from_street ~config ~p1_cards ~p2_cards
            ~board:full_board ~round_idx ~pot_so_far
        in
        Tree.node
          ~label:(Node_label.Chance {
            description = sprintf "opp=%s,%s board=%s"
              (Card.to_string opp1) (Card.to_string opp2)
              (String.concat ~sep:"," (List.map extra_board ~f:Card.to_string))
          })
          ~children:[ subtree ]))
  in
  Tree.node
    ~label:(Node_label.Chance {
      description = sprintf "p%d holds %s,%s at street %d"
        (player + 1) (Card.to_string h1) (Card.to_string h2) round_idx
    })
    ~children
