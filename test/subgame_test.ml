open! Core

(* ================================================================ *)
(* Subgame decomposition tests                                      *)
(* ================================================================ *)

(* subgame_key_to_string produces expected format. *)
let%test_unit "subgame_key_to_string_format" =
  let key : Subgame.subgame_key = { preflop_history = "cc"; flop_cluster = 3 } in
  [%test_eq: string] (Subgame.subgame_key_to_string key) "cc|3"

let%test_unit "subgame_key_to_string_empty_history" =
  let key : Subgame.subgame_key = { preflop_history = ""; flop_cluster = 0 } in
  [%test_eq: string] (Subgame.subgame_key_to_string key) "|0"

(* reconstruct_state produces round_idx=1 (flop) with correct structure. *)
let%test_unit "reconstruct_state_cc" =
  let config = Nolimit_holdem.short_stack_config in
  (* "cc" = SB calls, BB calls — both reach flop *)
  let state = Subgame.reconstruct_state ~config ~preflop_history:"cc" in
  [%test_eq: int] state.round_idx 1;
  (* Model convention: each call costs 2 (current_bet = big_blind) *)
  [%test_eq: int] state.p_invested.(0) 3;  (* small_blind=1 + call=2 *)
  [%test_eq: int] state.p_invested.(1) 4;  (* big_blind=2 + call=2 *)
  [%test_eq: int] state.p_stack.(0) (config.starting_stack - 3);
  [%test_eq: int] state.p_stack.(1) (config.starting_stack - 4);
  [%test_eq: int] state.actions_remaining 2;
  [%test_eq: int] state.to_act 0

(* reconstruct_state with a raise line. *)
let%test_unit "reconstruct_state_hc" =
  let config = Nolimit_holdem.short_stack_config in
  (* "hc" = SB raises half pot, BB calls *)
  let state = Subgame.reconstruct_state ~config ~preflop_history:"hc" in
  [%test_eq: int] state.round_idx 1;
  (* After raise + call, pot should be larger than "cc" *)
  assert (state.p_invested.(0) + state.p_invested.(1) > 7);
  [%test_eq: int] state.actions_remaining 2;
  [%test_eq: int] state.to_act 0

(* enumerate_preflop_histories returns non-empty list for short stack config. *)
let%test_unit "enumerate_preflop_histories_nonempty" =
  let config = Nolimit_holdem.short_stack_config in
  let histories = Subgame.enumerate_preflop_histories ~config () in
  assert (List.length histories > 0);
  (* "cc" should be one of the histories (SB calls, BB calls) *)
  assert (List.mem histories "cc" ~equal:String.equal)

(* enumerate_preflop_histories does not include fold sequences. *)
let%test_unit "enumerate_preflop_histories_no_folds" =
  let config = Nolimit_holdem.short_stack_config in
  let histories = Subgame.enumerate_preflop_histories ~config () in
  List.iter histories ~f:(fun h ->
    assert (not (String.mem h 'f')))

(* All enumerated histories reconstruct to round_idx=1. *)
let%test_unit "enumerate_preflop_histories_all_reach_flop" =
  let config = Nolimit_holdem.short_stack_config in
  let histories = Subgame.enumerate_preflop_histories ~config () in
  List.iter histories ~f:(fun h ->
    let state = Subgame.reconstruct_state ~config ~preflop_history:h in
    [%test_eq: int] state.round_idx 1)

(* flop_to_cluster returns 0 for unknown flops. *)
let%test_unit "flop_to_cluster_unknown_returns_0" =
  let cluster_map = Hashtbl.create (module String) in
  let board = List.take Card.full_deck 5 in
  let cluster = Subgame.flop_to_cluster ~cluster_map ~board in
  [%test_eq: int] cluster 0

(* flop_to_cluster finds a known flop. *)
let%test_unit "flop_to_cluster_known_flop" =
  let cluster_map = Hashtbl.create (module String) in
  let flop = List.take Card.full_deck 3 in
  (* Sort for canonical form *)
  let sorted = List.sort flop ~compare:Card.compare in
  let key = String.concat (List.map sorted ~f:Card.to_string) in
  Hashtbl.set cluster_map ~key ~data:7;
  let board = flop @ List.take (List.drop Card.full_deck 3) 2 in
  let cluster = Subgame.flop_to_cluster ~cluster_map ~board in
  [%test_eq: int] cluster 7

(* cluster_flops produces valid cluster assignments. *)
let%test_unit "cluster_flops_basic" =
  let config = Nolimit_holdem.short_stack_config in
  let result = Subgame.cluster_flops ~epsilon:1.0 ~n_sample_hands:2
      ~config ~n_flops:10 () in
  (* Should have entries *)
  assert (List.length result > 0);
  (* Each entry should have 3 cards *)
  List.iter result ~f:(fun (flop, cid) ->
    [%test_eq: int] (List.length flop) 3;
    assert (cid >= 0));
  (* At most n_flops entries *)
  assert (List.length result <= 10)
