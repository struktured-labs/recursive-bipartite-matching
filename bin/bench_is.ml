(** Quick benchmark of showdown distribution tree + RBM distance. *)

open Rbm

let () =
  let config = Limit_holdem.standard_config in
  let card r s = { Card.rank = r; suit = s } in
  let hole1 = (card Ace Hearts, card King Spades) in
  let hole2 = (card Queen Hearts, card Jack Spades) in
  let hole3 = (card Seven Clubs, card Two Diamonds) in
  let board_3 = [ card Two Clubs; card Five Diamonds; card Nine Hearts ] in
  let board_4 = board_3 @ [ card Jack Clubs ] in
  let board_5 = board_4 @ [ card Three Spades ] in

  printf "=== Showdown Distribution Tree Benchmarks ===\n%!";

  (* Flop *)
  let t0 = Core_unix.gettimeofday () in
  let t1 = Limit_holdem.showdown_distribution_tree ~max_opponents:15
      ~max_board_samples:5 ~config ~player:0
      ~hole_cards:hole1 ~board_visible:board_3 () in
  let t1_time = Core_unix.gettimeofday () in
  printf "AKs flop: size=%d leaves=%d  build=%.6fs\n%!"
    (Tree.size t1) (Tree.num_leaves t1) (t1_time -. t0);

  let t2_start = Core_unix.gettimeofday () in
  let t2 = Limit_holdem.showdown_distribution_tree ~max_opponents:15
      ~max_board_samples:5 ~config ~player:0
      ~hole_cards:hole2 ~board_visible:board_3 () in
  let t2_time = Core_unix.gettimeofday () in
  printf "QJs flop: size=%d leaves=%d  build=%.6fs\n%!"
    (Tree.size t2) (Tree.num_leaves t2) (t2_time -. t2_start);

  let t3_start = Core_unix.gettimeofday () in
  let t3 = Limit_holdem.showdown_distribution_tree ~max_opponents:15
      ~max_board_samples:5 ~config ~player:0
      ~hole_cards:hole3 ~board_visible:board_3 () in
  let t3_time = Core_unix.gettimeofday () in
  printf "72o flop: size=%d leaves=%d  build=%.6fs\n%!"
    (Tree.size t3) (Tree.num_leaves t3) (t3_time -. t3_start);

  (* Turn *)
  let t4_start = Core_unix.gettimeofday () in
  let t4 = Limit_holdem.showdown_distribution_tree ~max_opponents:15
      ~max_board_samples:5 ~config ~player:0
      ~hole_cards:hole1 ~board_visible:board_4 () in
  let t4_time = Core_unix.gettimeofday () in
  printf "AKs turn: size=%d leaves=%d  build=%.6fs\n%!"
    (Tree.size t4) (Tree.num_leaves t4) (t4_time -. t4_start);

  (* River *)
  let t5_start = Core_unix.gettimeofday () in
  let t5 = Limit_holdem.showdown_distribution_tree ~max_opponents:15
      ~max_board_samples:5 ~config ~player:0
      ~hole_cards:hole1 ~board_visible:board_5 () in
  let t5_time = Core_unix.gettimeofday () in
  printf "AKs river: size=%d leaves=%d  build=%.6fs\n%!"
    (Tree.size t5) (Tree.num_leaves t5) (t5_time -. t5_start);

  printf "\n=== Distance Benchmarks ===\n%!";
  let d_start = Core_unix.gettimeofday () in
  let d1 = Distance.compute_with_config ~config:Distance.default_config t1 t2 in
  let d_end = Core_unix.gettimeofday () in
  printf "AKs vs QJs (flop): distance=%.4f  time=%.6fs\n%!" d1 (d_end -. d_start);

  let d_start2 = Core_unix.gettimeofday () in
  let d2 = Distance.compute_with_config ~config:Distance.default_config t1 t3 in
  let d_end2 = Core_unix.gettimeofday () in
  printf "AKs vs 72o (flop): distance=%.4f  time=%.6fs\n%!" d2 (d_end2 -. d_start2);

  let d_start3 = Core_unix.gettimeofday () in
  let (d3, depth) = Distance.compute_progressive ~threshold:1.0 t1 t2 in
  let d_end3 = Core_unix.gettimeofday () in
  printf "Progressive AKs vs QJs (eps=1.0): distance=%.4f  depth=%d  time=%.6fs\n%!"
    d3 depth (d_end3 -. d_start3);

  (* Estimate for 100K iterations *)
  let build_us = (t1_time -. t0) *. 1_000_000.0 in
  let dist_us = (d_end -. d_start) *. 1_000_000.0 in
  printf "\n=== Performance Estimate for 100K MCCFR Iterations ===\n%!";
  printf "Tree build: %.0fus per call\n%!" build_us;
  printf "Full distance: %.0fus per pair\n%!" dist_us;
  printf "400K tree builds (2 players x 2 avg streets): %.1fs\n%!"
    (400_000.0 *. build_us /. 1_000_000.0);
  printf "Assuming ~10 clusters avg, 400K x 10 distance checks: %.1fs\n%!"
    (4_000_000.0 *. dist_us /. 1_000_000.0);
  printf "With EV pruning (skip ~80%%): %.1fs\n%!"
    (800_000.0 *. dist_us /. 1_000_000.0)
