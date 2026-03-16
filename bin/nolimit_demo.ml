open Rbm

(** No-Limit Hold'em demo: generate game trees and compare sizes with Limit. *)

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

let tree_stats label tree =
  let size = Tree.size tree in
  let depth = Tree.depth tree in
  let leaves = Tree.num_leaves tree in
  printf "  %s: nodes=%d  depth=%d  leaves=%d  EV=%.4f\n%!"
    label size depth leaves (Tree.ev tree)

let () =
  printf "=== No-Limit Hold'em Game Tree Demo ===\n\n%!";

  (* Fixed deal for comparison *)
  let p1_cards = (mk "Ah", mk "Kh") in
  let p2_cards = (mk "Qs", mk "Jd") in
  let board = [ mk "Th"; mk "9h"; mk "2c"; mk "8s"; mk "3d" ] in

  printf "Deal: P1=AhKh (nut flush)  P2=QsJd (straight)  Board=Th 9h 2c 8s 3d\n\n%!";

  (* 1) Limit Hold'em baseline *)
  printf "--- Limit Hold'em (baseline) ---\n%!";
  let limit_tree =
    Limit_holdem.game_tree_for_deal
      ~config:Limit_holdem.standard_config
      ~p1_cards ~p2_cards ~board
  in
  tree_stats "Limit HU" limit_tree;
  printf "\n%!";

  (* 2) No-Limit heads-up with short stacks (20bb) *)
  printf "--- No-Limit Heads-Up (20bb, fractions=[0.5; 1.0]) ---\n%!";
  let nl_short_tree =
    Nolimit_holdem.game_tree_for_deal
      ~config:Nolimit_holdem.short_stack_config
      ~p1_cards ~p2_cards ~board
  in
  tree_stats "NL-HU 20bb" nl_short_tree;
  printf "\n%!";

  (* 3) No-Limit heads-up with standard stacks (200bb) *)
  printf "--- No-Limit Heads-Up (200bb, fractions=[0.5; 1.0; 2.0]) ---\n%!";
  let nl_std_tree =
    Nolimit_holdem.game_tree_for_deal
      ~config:Nolimit_holdem.standard_config
      ~p1_cards ~p2_cards ~board
  in
  tree_stats "NL-HU 200bb" nl_std_tree;
  printf "\n%!";

  (* 4) 6-player short-stack NL *)
  printf "--- No-Limit 6-Max (20bb, fractions=[0.5; 1.0]) ---\n%!";
  let six_cards = [|
    (mk "Ah", mk "Kh");
    (mk "Qs", mk "Jd");
    (mk "7c", mk "6c");
    (mk "Ts", mk "9d");
    (mk "4h", mk "4d");
    (mk "Ac", mk "2s");
  |] in
  let six_players =
    let cfg = Nolimit_holdem.six_max_short_config in
    Array.mapi six_cards ~f:(fun i cards ->
      let invested =
        match i with
        | 0 -> cfg.small_blind
        | 1 -> cfg.big_blind
        | _ -> 0
      in
      let stack = cfg.starting_stack - invested in
      { Nolimit_holdem.cards
      ; stack
      ; folded = false
      ; all_in = false
      ; invested
      })
  in
  let nl_6max_tree =
    Nolimit_holdem.game_tree_for_deal_n
      ~config:Nolimit_holdem.six_max_short_config
      ~players:six_players
      ~board
  in
  tree_stats "NL 6-max 20bb" nl_6max_tree;
  printf "\n%!";

  (* 5) Summary comparison *)
  printf "=== Size Comparison ===\n%!";
  printf "  %-20s  %10s  %6s  %10s\n%!" "Variant" "Nodes" "Depth" "Leaves";
  printf "  %-20s  %10s  %6s  %10s\n%!" "--------------------" "----------" "------" "----------";
  let print_row name size depth leaves =
    printf "  %-20s  %10d  %6d  %10d\n%!" name size depth leaves
  in
  print_row "Limit HU" (Tree.size limit_tree) (Tree.depth limit_tree) (Tree.num_leaves limit_tree);
  print_row "NL-HU 20bb" (Tree.size nl_short_tree) (Tree.depth nl_short_tree) (Tree.num_leaves nl_short_tree);
  print_row "NL-HU 200bb" (Tree.size nl_std_tree) (Tree.depth nl_std_tree) (Tree.num_leaves nl_std_tree);
  print_row "NL 6-max 20bb" (Tree.size nl_6max_tree) (Tree.depth nl_6max_tree) (Tree.num_leaves nl_6max_tree);
  printf "\n%!";

  printf "=== Done ===\n%!"
