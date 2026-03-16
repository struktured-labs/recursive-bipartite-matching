open Rbm

(** Quick test for Phases 1-2: Hand_eval7, Hand_iso, Limit_holdem. *)

let mk card_str =
  let rank =
    match String.get card_str 0 with
    | 'A' -> Card.Rank.Ace | 'K' -> King | 'Q' -> Queen | 'J' -> Jack
    | 'T' -> Ten | '9' -> Nine | '8' -> Eight | '7' -> Seven
    | '6' -> Six | '5' -> Five | '4' -> Four | '3' -> Three | '2' -> Two
    | c -> failwithf "bad rank: %c" c ()
  in
  let suit =
    match String.get card_str 1 with
    | 'h' -> Card.Suit.Hearts | 'd' -> Diamonds | 'c' -> Clubs | 's' -> Spades
    | c -> failwithf "bad suit: %c" c ()
  in
  { Card.rank; suit }

let () =
  printf "=== Phase 1a: Hand_eval7 tests ===\n\n%!";

  (* Test 1: Full house beats flush *)
  let full_house_hand =
    [ mk "Ah"; mk "As"; mk "Kh"; mk "Ks"; mk "Kd"; mk "2h"; mk "3h" ]
  in
  let flush_hand =
    [ mk "Ah"; mk "Th"; mk "8h"; mk "6h"; mk "4h"; mk "2s"; mk "3s" ]
  in
  let (fh_rank, fh_tb) = Hand_eval7.evaluate7 full_house_hand in
  let (fl_rank, fl_tb) = Hand_eval7.evaluate7 flush_hand in
  printf "Full house hand: %s  kickers=%s\n%!"
    (Hand_eval5.Hand_rank.to_string fh_rank)
    (String.concat ~sep:"," (List.map fh_tb ~f:Int.to_string));
  printf "Flush hand:      %s  kickers=%s\n%!"
    (Hand_eval5.Hand_rank.to_string fl_rank)
    (String.concat ~sep:"," (List.map fl_tb ~f:Int.to_string));
  let cmp1 = Hand_eval7.compare_hands7 full_house_hand flush_hand in
  printf "Full house vs flush: %d (expected >0)\n%!" cmp1;
  assert (cmp1 > 0);
  printf "  PASS\n\n%!";

  (* Test 2: Straight flush beats four of a kind *)
  let sf_hand =
    [ mk "5h"; mk "6h"; mk "7h"; mk "8h"; mk "9h"; mk "2s"; mk "3d" ]
  in
  let quads_hand =
    [ mk "Qs"; mk "Qh"; mk "Qd"; mk "Qc"; mk "Ks"; mk "2h"; mk "3d" ]
  in
  let (sf_rank, _) = Hand_eval7.evaluate7 sf_hand in
  let (q_rank, _) = Hand_eval7.evaluate7 quads_hand in
  printf "Straight flush: %s\n%!" (Hand_eval5.Hand_rank.to_string sf_rank);
  printf "Four of a kind: %s\n%!" (Hand_eval5.Hand_rank.to_string q_rank);
  let cmp2 = Hand_eval7.compare_hands7 sf_hand quads_hand in
  printf "Straight flush vs quads: %d (expected >0)\n%!" cmp2;
  assert (cmp2 > 0);
  printf "  PASS\n\n%!";

  (* Test 3: Same rank, kicker decides *)
  let hand_a =
    [ mk "Ah"; mk "Kh"; mk "Qs"; mk "Jd"; mk "9c"; mk "2s"; mk "3d" ]
  in
  let hand_b =
    [ mk "Ad"; mk "Kd"; mk "Qc"; mk "Jh"; mk "8s"; mk "2h"; mk "3c" ]
  in
  let (ra, _) = Hand_eval7.evaluate7 hand_a in
  let (rb, _) = Hand_eval7.evaluate7 hand_b in
  printf "Hand A (9 kicker): %s\n%!" (Hand_eval5.Hand_rank.to_string ra);
  printf "Hand B (8 kicker): %s\n%!" (Hand_eval5.Hand_rank.to_string rb);
  let cmp3 = Hand_eval7.compare_hands7 hand_a hand_b in
  printf "A vs B: %d (expected >0, 9 kicker beats 8)\n%!" cmp3;
  assert (cmp3 > 0);
  printf "  PASS\n\n%!";

  (* Test 4: Tie *)
  let tie_a =
    [ mk "Ah"; mk "Kh"; mk "Qs"; mk "Jd"; mk "9c"; mk "2s"; mk "3d" ]
  in
  let tie_b =
    [ mk "Ad"; mk "Kd"; mk "Qc"; mk "Jh"; mk "9s"; mk "2h"; mk "3c" ]
  in
  let cmp4 = Hand_eval7.compare_hands7 tie_a tie_b in
  printf "Tie test: %d (expected 0)\n%!" cmp4;
  assert (cmp4 = 0);
  printf "  PASS\n\n%!";

  (* Test 5: Best-5 extraction - hand has pair in 7 but trips in best 5 *)
  let trips_hidden =
    [ mk "Ah"; mk "Ad"; mk "As"; mk "Kh"; mk "Qs"; mk "2c"; mk "3d" ]
  in
  let (th_rank, _) = Hand_eval7.evaluate7 trips_hidden in
  printf "Hidden trips hand: %s (expected three_of_a_kind)\n%!"
    (Hand_eval5.Hand_rank.to_string th_rank);
  assert (Hand_eval5.Hand_rank.equal th_rank Three_of_a_kind);
  printf "  PASS\n\n%!";

  printf "=== Phase 1b: Hand_iso tests ===\n\n%!";

  let all = Hand_iso.all_classes in
  printf "Total canonical classes: %d (expected 169)\n%!" (List.length all);
  assert (List.length all = 169);

  (* Check all IDs are unique and in [0, 168] *)
  let ids = List.map all ~f:Hand_iso.canonical_id in
  let id_set = Set.of_list (module Int) ids in
  printf "Unique IDs: %d (expected 169)\n%!" (Set.length id_set);
  assert (Set.length id_set = 169);
  assert (Set.min_elt_exn id_set = 0);
  assert (Set.max_elt_exn id_set = 168);
  printf "  PASS\n\n%!";

  (* Count pairs/suited/offsuit *)
  let n_pairs =
    List.count all ~f:(fun hc ->
      Card.Rank.to_int hc.rank1 = Card.Rank.to_int hc.rank2)
  in
  let n_suited =
    List.count all ~f:(fun hc ->
      Card.Rank.to_int hc.rank1 <> Card.Rank.to_int hc.rank2 && hc.suited)
  in
  let n_offsuit =
    List.count all ~f:(fun hc ->
      Card.Rank.to_int hc.rank1 <> Card.Rank.to_int hc.rank2
      && not hc.suited)
  in
  printf "Pairs: %d (expected 13), Suited: %d (expected 78), Offsuit: %d (expected 78)\n%!"
    n_pairs n_suited n_offsuit;
  assert (n_pairs = 13);
  assert (n_suited = 78);
  assert (n_offsuit = 78);
  printf "  PASS\n\n%!";

  (* Verify classify round-trips *)
  let ah = mk "Ah" in
  let kh = mk "Kh" in
  let ks = mk "Ks" in
  let ac = mk "Ac" in
  let aks = Hand_iso.classify ah kh in
  printf "AhKh -> %s (expected AKs)\n%!" (Hand_iso.to_string aks);
  assert (String.equal (Hand_iso.to_string aks) "AKs");

  let ako = Hand_iso.classify ah ks in
  printf "AhKs -> %s (expected AKo)\n%!" (Hand_iso.to_string ako);
  assert (String.equal (Hand_iso.to_string ako) "AKo");

  let aa = Hand_iso.classify ah ac in
  printf "AhAc -> %s (expected AA)\n%!" (Hand_iso.to_string aa);
  assert (String.equal (Hand_iso.to_string aa) "AA");
  printf "  PASS\n\n%!";

  (* Verify combo counts *)
  let total_combos =
    List.sum (module Int) all ~f:(fun hc ->
      List.length (Hand_iso.hands_in_class hc))
  in
  printf "Total combos across all classes: %d (expected C(52,2)=1326)\n%!" total_combos;
  assert (total_combos = 1326);
  printf "  PASS\n\n%!";

  (* Show first 20 classes *)
  printf "First 20 canonical classes:\n%!";
  List.iteri all ~f:(fun i hc ->
    match i < 20 with
    | true ->
      let combos = Hand_iso.hands_in_class hc in
      printf "  %3d: %-4s  id=%3d  combos=%d\n%!"
        i (Hand_iso.to_string hc) (Hand_iso.canonical_id hc) (List.length combos)
    | false -> ());
  printf "  ...\n\n%!";

  printf "=== Phase 2: Limit_holdem game tree tests ===\n\n%!";

  let config = Limit_holdem.standard_config in
  printf "Config: SB=%d BB=%d small_bet=%d big_bet=%d max_raises=%d\n%!"
    config.small_blind config.big_blind
    config.small_bet config.big_bet config.max_raises;

  (* Test with a specific deal *)
  let p1_cards = (mk "Ah", mk "Kh") in
  let p2_cards = (mk "Qs", mk "Jd") in
  let board = [ mk "Th"; mk "9h"; mk "2c"; mk "8s"; mk "3d" ] in

  printf "\nDeal: P1=%s%s  P2=%s%s  Board=%s\n%!"
    (Card.to_string (fst p1_cards)) (Card.to_string (snd p1_cards))
    (Card.to_string (fst p2_cards)) (Card.to_string (snd p2_cards))
    (String.concat ~sep:" " (List.map board ~f:Card.to_string));

  let (p1_rank, _) =
    Hand_eval7.evaluate7 ([ fst p1_cards; snd p1_cards ] @ board)
  in
  let (p2_rank, _) =
    Hand_eval7.evaluate7 ([ fst p2_cards; snd p2_cards ] @ board)
  in
  printf "P1 best hand: %s\n%!" (Hand_eval5.Hand_rank.to_string p1_rank);
  printf "P2 best hand: %s\n\n%!" (Hand_eval5.Hand_rank.to_string p2_rank);

  let tree = Limit_holdem.game_tree_for_deal ~config ~p1_cards ~p2_cards ~board in
  let size = Tree.size tree in
  let depth = Tree.depth tree in
  let leaves = Tree.num_leaves tree in
  printf "Game tree: size=%d  depth=%d  leaves=%d\n%!" size depth leaves;
  printf "Tree EV (P1 perspective): %+.4f\n\n%!" (Tree.ev tree);

  (* Verify basic sanity: tree should have at least fold/call/raise branches *)
  (match tree with
   | Tree.Node { children; label = Rhode_island.Node_label.Decision { player; actions_available } } ->
     printf "Root: player=%d  actions=%s  children=%d\n%!"
       player
       (String.concat ~sep:"," (List.map actions_available ~f:Rhode_island.Action.to_string))
       (List.length children)
   | _ -> printf "Root is not a decision node (unexpected)\n%!");
  printf "\n%!";

  (* Test with a couple more deals *)
  let deals = [
    (* Deal 2: P1 has pocket aces *)
    ((mk "Ah", mk "Ad"), (mk "7s", mk "2c"),
     [ mk "Ks"; mk "Jh"; mk "4d"; mk "9c"; mk "3s" ]);
    (* Deal 3: Both have drawing hands *)
    ((mk "Jh", mk "Th"), (mk "9d", mk "8d"),
     [ mk "Qc"; mk "6h"; mk "5d"; mk "2s"; mk "As" ]);
    (* Deal 4: P1 has a flush *)
    ((mk "Ah", mk "7h"), (mk "Ks", mk "Qd"),
     [ mk "2h"; mk "5h"; mk "9h"; mk "Jc"; mk "3s" ]);
  ] in

  List.iteri deals ~f:(fun i ((p1, p2, bd)) ->
    let t = Limit_holdem.game_tree_for_deal ~config
      ~p1_cards:p1 ~p2_cards:p2 ~board:bd
    in
    let (r1, _) = Hand_eval7.evaluate7 ([ fst p1; snd p1 ] @ bd) in
    let (r2, _) = Hand_eval7.evaluate7 ([ fst p2; snd p2 ] @ bd) in
    printf "Deal %d: size=%d depth=%d leaves=%d  P1=%s P2=%s  EV=%+.4f\n%!"
      (i + 2) (Tree.size t) (Tree.depth t) (Tree.num_leaves t)
      (Hand_eval5.Hand_rank.to_string r1)
      (Hand_eval5.Hand_rank.to_string r2)
      (Tree.ev t));
  printf "\n%!";

  (* Verify all trees have the same structure (same config, all 4 rounds) *)
  let sizes =
    List.map deals ~f:(fun (p1, p2, bd) ->
      Tree.size
        (Limit_holdem.game_tree_for_deal ~config ~p1_cards:p1 ~p2_cards:p2 ~board:bd))
  in
  let all_same = List.for_all sizes ~f:(fun s -> s = List.hd_exn sizes) in
  printf "All deal trees same size: %b (expected: true, since tree structure\n%!"
    all_same;
  printf "  depends only on config, not the cards)\n%!";
  assert all_same;
  printf "  PASS\n\n%!";

  (* Quick performance check: how big is the tree with max_raises=4? *)
  printf "Tree structure summary (max_raises=%d):\n%!" config.max_raises;
  printf "  Nodes:  %d\n%!" size;
  printf "  Leaves: %d\n%!" leaves;
  printf "  Depth:  %d\n%!" depth;
  printf "  4 betting rounds x limit structure = manageable game tree\n\n%!";

  (* Test with reduced max_raises to show scaling *)
  List.iter [ 1; 2; 3; 4 ] ~f:(fun mr ->
    let cfg = { config with max_raises = mr } in
    let t = Limit_holdem.game_tree_for_deal ~config:cfg ~p1_cards ~p2_cards ~board in
    printf "  max_raises=%d: size=%d depth=%d leaves=%d\n%!"
      mr (Tree.size t) (Tree.depth t) (Tree.num_leaves t));
  printf "\n%!";

  printf "=== All tests passed ===\n%!"
