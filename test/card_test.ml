open! Core

(* ================================================================ *)
(* Card.t int representation tests                                  *)
(* ================================================================ *)

(* Card.create + Card.rank/Card.suit round-trips correctly for all 52 cards. *)
let%test_unit "card_create_rank_suit_roundtrip_all_52" =
  List.iter Card.Rank.all ~f:(fun rank ->
    List.iter Card.Suit.all ~f:(fun suit ->
      let c = Card.create ~rank ~suit in
      let r' = Card.rank c in
      let s' = Card.suit c in
      [%test_eq: bool] true (Card.Rank.equal r' rank);
      [%test_eq: bool] true (Card.Suit.equal s' suit)))

(* Card.to_int / Card.of_int_exn round-trips for all 52 cards. *)
let%test_unit "card_to_int_of_int_roundtrip_all_52" =
  List.iter Card.full_deck ~f:(fun c ->
    let i = Card.to_int c in
    let c' = Card.of_int_exn i in
    [%test_eq: bool] true (Card.equal c c'))

(* Card.to_int produces values in [0, 51] for the full deck. *)
let%test_unit "card_to_int_range" =
  List.iter Card.full_deck ~f:(fun c ->
    let i = Card.to_int c in
    assert (i >= 0 && i <= 51))

(* All 52 cards have distinct int representations. *)
let%test_unit "card_to_int_all_distinct" =
  let ints = List.map Card.full_deck ~f:Card.to_int in
  let unique = Set.of_list (module Int) ints in
  [%test_eq: int] (Set.length unique) 52

(* Card.equal works correctly: same card is equal, different cards are not. *)
let%test_unit "card_equal_same" =
  let c = Card.create ~rank:Card.Rank.Ace ~suit:Card.Suit.Spades in
  let c2 = Card.create ~rank:Card.Rank.Ace ~suit:Card.Suit.Spades in
  assert (Card.equal c c2)

let%test_unit "card_equal_different_rank" =
  let c1 = Card.create ~rank:Card.Rank.Ace ~suit:Card.Suit.Spades in
  let c2 = Card.create ~rank:Card.Rank.King ~suit:Card.Suit.Spades in
  assert (not (Card.equal c1 c2))

let%test_unit "card_equal_different_suit" =
  let c1 = Card.create ~rank:Card.Rank.Ace ~suit:Card.Suit.Spades in
  let c2 = Card.create ~rank:Card.Rank.Ace ~suit:Card.Suit.Hearts in
  assert (not (Card.equal c1 c2))

(* Card.compare produces consistent ordering:
   - reflexive (compare c c = 0)
   - antisymmetric (compare a b and compare b a have opposite signs)
   - transitive *)
let%test_unit "card_compare_reflexive" =
  List.iter Card.full_deck ~f:(fun c ->
    [%test_eq: int] (Card.compare c c) 0)

let%test_unit "card_compare_antisymmetric" =
  let deck = Card.full_deck in
  let arr = Array.of_list deck in
  for i = 0 to Array.length arr - 2 do
    for j = i + 1 to Array.length arr - 1 do
      let cmp_ij = Card.compare arr.(i) arr.(j) in
      let cmp_ji = Card.compare arr.(j) arr.(i) in
      (* If one is positive, other must be negative, or both zero *)
      assert (cmp_ij + cmp_ji = 0 || (cmp_ij > 0 && cmp_ji < 0) || (cmp_ij < 0 && cmp_ji > 0))
    done
  done

let%test_unit "card_compare_transitive" =
  (* Sort the deck and verify ordering is maintained *)
  let sorted = List.sort Card.full_deck ~compare:Card.compare in
  let arr = Array.of_list sorted in
  for i = 0 to Array.length arr - 2 do
    assert (Card.compare arr.(i) arr.(i + 1) <= 0)
  done

(* Card.of_int_exn rejects out-of-range values. *)
let%test_unit "card_of_int_exn_rejects_negative" =
  match Card.of_int_exn (-1) with
  | exception _ -> ()
  | _ -> assert false

let%test_unit "card_of_int_exn_rejects_52" =
  match Card.of_int_exn 52 with
  | exception _ -> ()
  | _ -> assert false

(* Full deck has exactly 52 cards. *)
let%test_unit "card_full_deck_size" =
  [%test_eq: int] (List.length Card.full_deck) 52

(* Card.to_string produces 2-character strings for all cards. *)
let%test_unit "card_to_string_length" =
  List.iter Card.full_deck ~f:(fun c ->
    [%test_eq: int] (String.length (Card.to_string c)) 2)

(* ================================================================ *)
(* make_info_key tests (Compact_cfr)                                *)
(* ================================================================ *)

(* make_info_key produces consistent results: same inputs produce same output. *)
let%test_unit "make_info_key_consistent" =
  let buckets = [| 3; 7; 2; 5 |] in
  let key1 = Compact_cfr.make_info_key ~buckets ~round_idx:2 ~history:"rrc/kb" in
  let key2 = Compact_cfr.make_info_key ~buckets ~round_idx:2 ~history:"rrc/kb" in
  [%test_eq: int64] key1 key2

(* Different inputs produce different keys (basic collision test). *)
let%test_unit "make_info_key_different_buckets" =
  let b1 = [| 3; 7; 2; 5 |] in
  let b2 = [| 3; 7; 2; 6 |] in
  let k1 = Compact_cfr.make_info_key ~buckets:b1 ~round_idx:3 ~history:"rc" in
  let k2 = Compact_cfr.make_info_key ~buckets:b2 ~round_idx:3 ~history:"rc" in
  assert (not (Int64.equal k1 k2))

let%test_unit "make_info_key_different_history" =
  let buckets = [| 3; 7; 2; 5 |] in
  let k1 = Compact_cfr.make_info_key ~buckets ~round_idx:1 ~history:"rc" in
  let k2 = Compact_cfr.make_info_key ~buckets ~round_idx:1 ~history:"rr" in
  assert (not (Int64.equal k1 k2))

let%test_unit "make_info_key_different_round" =
  let buckets = [| 3; 7; 2; 5 |] in
  let k1 = Compact_cfr.make_info_key ~buckets ~round_idx:0 ~history:"rc" in
  let k2 = Compact_cfr.make_info_key ~buckets ~round_idx:1 ~history:"rc" in
  assert (not (Int64.equal k1 k2))

(* make_info_key_string produces readable string keys useful for debugging. *)
let%test_unit "make_info_key_string_format" =
  let buckets = [| 5; 12; 0; 8 |] in
  let key = Compact_cfr.make_info_key_string ~buckets ~round_idx:2 ~history:"rrc/kb" in
  (* Key should start with 'B', contain bucket values, and end with history *)
  assert (Char.equal (String.get key 0) 'B');
  assert (String.is_suffix key ~suffix:"rrc/kb")

let%test_unit "make_info_key_preflop_only" =
  let buckets = [| 9; 0; 0; 0 |] in
  let key = Compact_cfr.make_info_key_string ~buckets ~round_idx:0 ~history:"" in
  (* Should be "B9|" -- bucket 9, pipe, empty history *)
  [%test_eq: string] key "B9|"
