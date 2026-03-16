(** Quick validation of ACPC protocol parser. *)

open Rbm

let () =
  printf "=== ACPC Protocol Parser Tests ===\n\n%!";

  (* Test card parsing *)
  let test_card s expected_rank expected_suit =
    let c = Acpc_protocol.parse_card s in
    let ok = Card.Rank.equal c.rank expected_rank && Card.Suit.equal c.suit expected_suit in
    printf "  parse_card %S -> %s%s %s\n%!" s (Card.Rank.to_string c.rank)
      (match ok with true -> "" | false -> " FAIL!")
      (Card.Suit.to_string c.suit);
    assert ok
  in
  printf "Card parsing:\n%!";
  test_card "Ah" Card.Rank.Ace Card.Suit.Hearts;
  test_card "Td" Card.Rank.Ten Card.Suit.Diamonds;
  test_card "2c" Card.Rank.Two Card.Suit.Clubs;
  test_card "Ks" Card.Rank.King Card.Suit.Spades;
  test_card "9h" Card.Rank.Nine Card.Suit.Hearts;

  (* Test matchstate parsing *)
  printf "\nMatchstate parsing:\n%!";

  let ms1 = Acpc_protocol.parse_matchstate "MATCHSTATE:0:0::AhKd" in
  printf "  MATCHSTATE:0:0::AhKd\n%!";
  printf "    pos=%d hand=%d street=%d our_turn=%b board=%d\n%!"
    ms1.position ms1.hand_number ms1.current_street ms1.is_our_turn
    (List.length ms1.board);
  printf "    hole=%s%s\n%!"
    (Card.to_string (fst ms1.hole_cards))
    (Card.to_string (snd ms1.hole_cards));
  assert (ms1.position = 0);
  assert (ms1.hand_number = 0);
  assert (ms1.current_street = 0);
  assert ms1.is_our_turn;
  assert (List.length ms1.board = 0);

  let ms2 = Acpc_protocol.parse_matchstate "MATCHSTATE:1:5:r:AhKd" in
  printf "  MATCHSTATE:1:5:r:AhKd\n%!";
  printf "    pos=%d hand=%d street=%d our_turn=%b\n%!"
    ms2.position ms2.hand_number ms2.current_street ms2.is_our_turn;
  assert (ms2.position = 1);
  assert ms2.is_our_turn;

  let ms3 = Acpc_protocol.parse_matchstate "MATCHSTATE:0:10:rc/:AhKd|9s8h2c" in
  printf "  MATCHSTATE:0:10:rc/:AhKd|9s8h2c\n%!";
  printf "    pos=%d street=%d our_turn=%b board=%d: %s\n%!"
    ms3.position ms3.current_street ms3.is_our_turn (List.length ms3.board)
    (String.concat ~sep:" " (List.map ms3.board ~f:Card.to_string));
  assert (ms3.current_street = 1);
  assert ms3.is_our_turn;
  assert (List.length ms3.board = 3);

  let ms4 = Acpc_protocol.parse_matchstate "MATCHSTATE:0:0:rf:AhKd" in
  printf "  MATCHSTATE:0:0:rf:AhKd (fold)\n%!";
  printf "    pos=%d street=%d our_turn=%b\n%!"
    ms4.position ms4.current_street ms4.is_our_turn;
  assert (not ms4.is_our_turn);

  let ms5 = Acpc_protocol.parse_matchstate "MATCHSTATE:0:0:r:AhKd" in
  printf "  MATCHSTATE:0:0:r:AhKd (after our raise, opponent's turn)\n%!";
  printf "    pos=%d our_turn=%b\n%!" ms5.position ms5.is_our_turn;
  assert (not ms5.is_our_turn);

  let ms6 = Acpc_protocol.parse_matchstate "MATCHSTATE:0:0:rc/cc/cc/:AhKd|9s8h2c|Jd|7s" in
  printf "  MATCHSTATE:0:0:rc/cc/cc/:AhKd|9s8h2c|Jd|7s\n%!";
  printf "    pos=%d street=%d board=%d our_turn=%b\n%!"
    ms6.position ms6.current_street (List.length ms6.board) ms6.is_our_turn;
  assert (ms6.current_street = 3);
  assert (List.length ms6.board = 5);
  assert ms6.is_our_turn;

  (* Test valid actions *)
  printf "\nValid actions:\n%!";
  let show_actions label ms =
    let actions = Acpc_protocol.valid_actions ms in
    printf "  %s: [%s]\n%!" label
      (String.concat ~sep:", " (List.map actions ~f:Acpc_protocol.format_action))
  in
  show_actions "preflop opening (facing BB)" ms1;
  show_actions "after raise (facing raise)" ms2;
  show_actions "flop opening (no bet)" ms3;

  let ms_maxraise = Acpc_protocol.parse_matchstate "MATCHSTATE:1:0:rrrr:AhKd" in
  show_actions "after 4 raises (max)" ms_maxraise;

  (* Test action formatting *)
  printf "\nAction formatting:\n%!";
  printf "  fold=%s call=%s raise=%s\n%!"
    (Acpc_protocol.format_action `Fold)
    (Acpc_protocol.format_action `Call)
    (Acpc_protocol.format_action `Raise);

  (* Test history conversion *)
  printf "\nHistory conversion (ACPC -> internal):\n%!";
  let test_history acpc expected =
    let result = Acpc_protocol.acpc_to_internal_history acpc in
    let ok = String.equal result expected in
    printf "  %S -> %S%s\n%!" acpc result
      (match ok with true -> " OK" | false -> sprintf " (expected %S FAIL!)" expected);
    assert ok
  in
  (* Preflop: initial bet_outstanding=true (BB's blind)
     'r' with bet_outstanding -> raise (r), stays outstanding
     'c' with bet_outstanding -> call (c), clears outstanding
     'c' with no bet -> check (k) *)
  test_history "r" "r";
  test_history "rc" "rc";
  test_history "rrc" "rrc";
  (* Preflop cc: SB calls (c), BB checks (k) *)
  test_history "cc" "ck";
  (* Preflop raise-raise-call / flop check-check *)
  test_history "rrc/cc" "rrc/kk";
  (* Preflop call / flop check-bet *)
  test_history "cc/cr" "ck/kb";
  (* Preflop r-r-c / flop k-b-c / turn k-k *)
  test_history "rrc/crc/cc" "rrc/kbc/kk";

  (* Showdown format: both players' cards visible *)
  let ms_showdown = Acpc_protocol.parse_matchstate
      "MATCHSTATE:0:0:rc/cc/cc/cc:AhKd9s8h|2cJdTs|7s|Qc" in
  printf "\nShowdown (both visible):\n%!";
  printf "  hole=%s%s board=%d\n%!"
    (Card.to_string (fst ms_showdown.hole_cards))
    (Card.to_string (snd ms_showdown.hole_cards))
    (List.length ms_showdown.board);
  assert (List.length ms_showdown.board = 5);

  printf "\nAll ACPC protocol tests PASSED!\n%!"
