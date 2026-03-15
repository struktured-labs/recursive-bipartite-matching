module Action = struct
  type t = Fold | Check | Call | Bet | Raise
  [@@deriving sexp, compare, equal]

  let to_string = function
    | Fold -> "fold" | Check -> "check" | Call -> "call"
    | Bet -> "bet" | Raise -> "raise"
end

module Node_label = struct
  type t =
    | Root
    | Chance of { description : string }
    | Decision of { player : int; actions_available : Action.t list }
    | Terminal of { winner : int option; pot : int }
  [@@deriving sexp]
end

type config = {
  deck : Card.t list;
  ante : int;
  bet_sizes : int list;
  max_raises : int;
} [@@deriving sexp]

let standard_config =
  { deck = Card.full_deck
  ; ante = 5
  ; bet_sizes = [ 10; 20; 20 ]
  ; max_raises = 3
  }

let small_config ~n_ranks =
  { deck = Card.small_deck ~n_ranks
  ; ante = 5
  ; bet_sizes = [ 10; 20; 20 ]
  ; max_raises = 3
  }

(** Betting round state *)
type round_state = {
  to_act : int;          (** 0 or 1 *)
  num_raises : int;      (** total raises this round (bet counts as first raise) *)
  bet_outstanding : bool; (** is there an unmatched bet? *)
  first_checked : bool;  (** did the first-to-act player check? *)
  p1_invested : int;
  p2_invested : int;
  round_idx : int;
}

let showdown_value ~p1_card ~p2_card ~community ~pot =
  match community with
  | [ flop; turn ] ->
    let hand1 = (p1_card, flop, turn) in
    let hand2 = (p2_card, flop, turn) in
    let cmp = Hand_eval.compare_hands hand1 hand2 in
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

let rec advance_to_next_round ~config ~p1_card ~p2_card ~community ~state =
  let next_round = state.round_idx + 1 in
  let num_rounds = List.length config.bet_sizes in
  match next_round >= num_rounds with
  | true ->
    let pot = state.p1_invested + state.p2_invested in
    showdown_value ~p1_card ~p2_card ~community ~pot
  | false ->
    let new_state = {
      state with
      to_act = 0;
      num_raises = 0;
      bet_outstanding = false;
      first_checked = false;
      round_idx = next_round;
    } in
    betting_round ~config ~p1_card ~p2_card ~community ~state:new_state

and betting_round ~config ~p1_card ~p2_card ~community ~state : Node_label.t Tree.t =
  let player = state.to_act in
  let bet_sz = bet_size_for_round config state.round_idx in
  let pot = state.p1_invested + state.p2_invested in

  match state.bet_outstanding with
  | true ->
    (* Facing a bet: fold, call, raise *)
    let fold_child = fold_value ~folder:player ~pot in
    let call_state =
      add_to_invested { state with bet_outstanding = false } player bet_sz
    in
    (* Call ends the betting round *)
    let call_child =
      advance_to_next_round ~config ~p1_card ~p2_card ~community ~state:call_state
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
        let raise_child = betting_round ~config ~p1_card ~p2_card ~community ~state:raise_state in
        ([ Action.Fold; Call; Raise ], [ fold_child; call_child; raise_child ])
      | false ->
        ([ Action.Fold; Call ], [ fold_child; call_child ])
    in
    Tree.node
      ~label:(Node_label.Decision { player; actions_available = actions })
      ~children

  | false ->
    (* No bet outstanding: check or bet *)
    (* If first player already checked and second also checks -> round over *)
    let check_ends_round = state.first_checked in
    let check_child =
      match check_ends_round with
      | true ->
        advance_to_next_round ~config ~p1_card ~p2_card ~community ~state
      | false ->
        betting_round ~config ~p1_card ~p2_card ~community
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
        let bet_child = betting_round ~config ~p1_card ~p2_card ~community ~state:bet_state in
        ([ Action.Check; Bet ], [ check_child; bet_child ])
      | false ->
        ([ Action.Check ], [ check_child ])
    in
    Tree.node
      ~label:(Node_label.Decision { player; actions_available = actions })
      ~children

let game_tree_for_deal ~config ~p1_card ~p2_card ~community =
  let state = {
    to_act = 0;
    num_raises = 0;
    bet_outstanding = false;
    first_checked = false;
    p1_invested = config.ante;
    p2_invested = config.ante;
    round_idx = 0;
  } in
  betting_round ~config ~p1_card ~p2_card ~community ~state

let remove_card deck card =
  List.filter deck ~f:(fun c -> not (Card.equal c card))

let num_deals ~config =
  let n = List.length config.deck in
  n * (n - 1) * (n - 2) * (n - 3)

let full_game_tree ~config =
  let deck = config.deck in
  let deal_children =
    List.concat_map deck ~f:(fun p1_card ->
      let deck1 = remove_card deck p1_card in
      List.concat_map deck1 ~f:(fun p2_card ->
        let deck2 = remove_card deck1 p2_card in
        List.concat_map deck2 ~f:(fun flop ->
          let deck3 = remove_card deck2 flop in
          List.map deck3 ~f:(fun turn ->
            let community = [ flop; turn ] in
            let subtree = game_tree_for_deal ~config ~p1_card ~p2_card ~community in
            Tree.node
              ~label:(Node_label.Chance {
                description = sprintf "deal: p1=%s p2=%s flop=%s turn=%s"
                  (Card.to_string p1_card) (Card.to_string p2_card)
                  (Card.to_string flop) (Card.to_string turn)
              })
              ~children:[ subtree ]))))
  in
  Tree.node ~label:Node_label.Root ~children:deal_children

let information_set_tree ~config ~player ~hole_card ~community =
  let deck = config.deck in
  let remaining = remove_card deck hole_card in
  let remaining =
    List.fold community ~init:remaining ~f:(fun d c -> remove_card d c)
  in
  let opponent_children =
    List.map remaining ~f:(fun opp_card ->
      let p1_card, p2_card =
        match player with
        | 0 -> (hole_card, opp_card)
        | _ -> (opp_card, hole_card)
      in
      let subtree = game_tree_for_deal ~config ~p1_card ~p2_card ~community in
      Tree.node
        ~label:(Node_label.Chance {
          description = sprintf "opp=%s" (Card.to_string opp_card)
        })
        ~children:[ subtree ])
  in
  Tree.node
    ~label:(Node_label.Chance {
      description = sprintf "p%d holds %s" (player + 1) (Card.to_string hole_card)
    })
    ~children:opponent_children
