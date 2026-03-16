(** Mini Texas Hold'em: 2 hole cards, 3 community cards, 5-card evaluation.

    Reuses the Rhode Island betting round logic (same action/node_label types).
    Key difference: showdown uses Hand_eval5 for 5-card poker hands. *)

module Action = Rhode_island.Action
module Node_label = Rhode_island.Node_label

type config = {
  deck : Card.t list;
  ante : int;
  bet_sizes : int list;
  max_raises : int;
} [@@deriving sexp]

let default_config =
  { deck = Card.small_deck ~n_ranks:6  (* 2-7, 24 cards *)
  ; ante = 5
  ; bet_sizes = [ 10; 20 ]
  ; max_raises = 1
  }

(** Remove a list of cards from a deck. *)
let remove_cards deck cards =
  List.filter deck ~f:(fun c ->
    not (List.exists cards ~f:(fun cc -> Card.equal c cc)))

(** All unordered 2-card combinations from a list. *)
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

(** Betting round state (same structure as Rhode Island). *)
type round_state = {
  to_act : int;
  num_raises : int;
  bet_outstanding : bool;
  first_checked : bool;
  p1_invested : int;
  p2_invested : int;
  round_idx : int;
}

let showdown_value ~p1_cards ~p2_cards ~community ~pot =
  match community with
  | [ c1; c2; c3 ] ->
    let (p1a, p1b) = p1_cards in
    let (p2a, p2b) = p2_cards in
    let hand1 = (p1a, p1b, c1, c2, c3) in
    let hand2 = (p2a, p2b, c1, c2, c3) in
    let cmp = Hand_eval5.compare_hands5 hand1 hand2 in
    let winner =
      match cmp > 0 with
      | true -> Some 0
      | false ->
        (match cmp < 0 with
         | true -> Some 1
         | false -> None)
    in
    Tree.leaf
      ~label:(Node_label.Terminal { winner; pot })
      ~value:(match winner with
        | Some 0 -> Float.of_int (pot / 2)
        | Some _ -> Float.of_int (-(pot / 2))
        | None -> 0.0)
  | _ ->
    Tree.leaf ~label:(Node_label.Terminal { winner = None; pot }) ~value:0.0

let fold_value ~folder ~pot =
  let winner = match folder with 0 -> 1 | _ -> 0 in
  let value =
    match folder with
    | 0 -> Float.of_int (-(pot / 2))
    | _ -> Float.of_int (pot / 2)
  in
  Tree.leaf ~label:(Node_label.Terminal { winner = Some winner; pot }) ~value

let bet_size_for_round config round_idx =
  match List.nth config.bet_sizes round_idx with
  | Some s -> s
  | None -> List.last_exn config.bet_sizes

let add_to_invested state player amount =
  match player with
  | 0 -> { state with p1_invested = state.p1_invested + amount }
  | _ -> { state with p2_invested = state.p2_invested + amount }

let rec advance_to_next_round ~config ~p1_cards ~p2_cards ~community ~state =
  let next_round = state.round_idx + 1 in
  let num_rounds = List.length config.bet_sizes in
  match next_round >= num_rounds with
  | true ->
    let pot = state.p1_invested + state.p2_invested in
    showdown_value ~p1_cards ~p2_cards ~community ~pot
  | false ->
    let new_state = {
      state with
      to_act = 0;
      num_raises = 0;
      bet_outstanding = false;
      first_checked = false;
      round_idx = next_round;
    } in
    betting_round ~config ~p1_cards ~p2_cards ~community ~state:new_state

and betting_round ~config ~p1_cards ~p2_cards ~community ~state
    : Node_label.t Tree.t =
  let player = state.to_act in
  let bet_sz = bet_size_for_round config state.round_idx in
  let pot = state.p1_invested + state.p2_invested in

  match state.bet_outstanding with
  | true ->
    let fold_child = fold_value ~folder:player ~pot in
    let call_state =
      add_to_invested { state with bet_outstanding = false } player bet_sz
    in
    let call_child =
      advance_to_next_round ~config ~p1_cards ~p2_cards ~community ~state:call_state
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
          betting_round ~config ~p1_cards ~p2_cards ~community ~state:raise_state
        in
        ([ Action.Fold; Call; Raise ], [ fold_child; call_child; raise_child ])
      | false ->
        ([ Action.Fold; Call ], [ fold_child; call_child ])
    in
    Tree.node
      ~label:(Node_label.Decision { player; actions_available = actions })
      ~children

  | false ->
    let check_ends_round = state.first_checked in
    let check_child =
      match check_ends_round with
      | true ->
        advance_to_next_round ~config ~p1_cards ~p2_cards ~community ~state
      | false ->
        betting_round ~config ~p1_cards ~p2_cards ~community
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
          betting_round ~config ~p1_cards ~p2_cards ~community ~state:bet_state
        in
        ([ Action.Check; Bet ], [ check_child; bet_child ])
      | false ->
        ([ Action.Check ], [ check_child ])
    in
    Tree.node
      ~label:(Node_label.Decision { player; actions_available = actions })
      ~children

let game_tree_for_deal ~config ~p1_cards ~p2_cards ~community =
  let state = {
    to_act = 0;
    num_raises = 0;
    bet_outstanding = false;
    first_checked = false;
    p1_invested = config.ante;
    p2_invested = config.ante;
    round_idx = 0;
  } in
  betting_round ~config ~p1_cards ~p2_cards ~community ~state

let information_set_tree ~config ~player ~hole_cards ~community =
  let (h1, h2) = hole_cards in
  let dealt = [ h1; h2 ] @ community in
  let remaining = remove_cards config.deck dealt in
  let opponent_hands = all_pairs remaining in
  let opponent_children =
    List.map opponent_hands ~f:(fun (opp1, opp2) ->
      let p1_cards, p2_cards =
        match player with
        | 0 -> (hole_cards, (opp1, opp2))
        | _ -> ((opp1, opp2), hole_cards)
      in
      let subtree = game_tree_for_deal ~config ~p1_cards ~p2_cards ~community in
      Tree.node
        ~label:(Node_label.Chance {
          description = sprintf "opp=%s,%s"
            (Card.to_string opp1) (Card.to_string opp2)
        })
        ~children:[ subtree ])
  in
  Tree.node
    ~label:(Node_label.Chance {
      description = sprintf "p%d holds %s,%s"
        (player + 1) (Card.to_string h1) (Card.to_string h2)
    })
    ~children:opponent_children
