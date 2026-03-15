open Rbm

let time f =
  let t0 = Core_unix.gettimeofday () in
  let result = f () in
  let t1 = Core_unix.gettimeofday () in
  (result, t1 -. t0)

let () =
  printf "=== Recursive Bipartite Matching on Game Trees ===\n\n";

  (* === Part 0: Sanity checks === *)
  printf "--- Part 0: Sanity checks ---\n\n%!";

  let t1 = Tree.node ~label:"A" ~children:[
    Tree.leaf ~label:"a1" ~value:10.0;
    Tree.leaf ~label:"a2" ~value:20.0;
  ] in
  let t2 = Tree.node ~label:"B" ~children:[
    Tree.leaf ~label:"b1" ~value:10.0;
    Tree.leaf ~label:"b2" ~value:20.0;
  ] in
  let t3 = Tree.node ~label:"C" ~children:[
    Tree.leaf ~label:"c1" ~value:15.0;
    Tree.leaf ~label:"c2" ~value:25.0;
  ] in
  let t4 = Tree.node ~label:"D" ~children:[
    Tree.leaf ~label:"d1" ~value:10.0;
    Tree.leaf ~label:"d2" ~value:20.0;
    Tree.leaf ~label:"d3" ~value:30.0;
  ] in

  printf "d(t1,t2) = %.2f  (identical values, expect 0)\n%!" (Distance.compute t1 t2);
  printf "d(t1,t3) = %.2f  (shifted +5, expect 10)\n%!" (Distance.compute t1 t3);
  printf "d(t1,t4) = %.2f  (extra child)\n%!" (Distance.compute t1 t4);
  printf "d(t1,t1) = %.2f  (self, expect 0)\n%!" (Distance.compute t1 t1);

  let d12 = Distance.compute t1 t2 in
  let d13 = Distance.compute t1 t3 in
  let d23 = Distance.compute t2 t3 in
  printf "Triangle: d(1,3)=%.2f <= d(1,2)+d(2,3)=%.2f  %s\n\n%!"
    d13 (d12 +. d23)
    (match Float.( <= ) d13 (d12 +. d23 +. 0.001) with
     | true -> "PASS" | false -> "FAIL");

  (* Merge test *)
  let merged = Merge.merge ~config:Merge.default_config t1 t3 in
  printf "Merge t1+t3: EV=%.2f (t1=%.2f, t3=%.2f, avg=%.2f)\n\n%!"
    (Tree.ev merged) (Tree.ev t1) (Tree.ev t3)
    ((Tree.ev t1 +. Tree.ev t3) /. 2.0);

  (* Deeper tree *)
  let deep1 = Tree.node ~label:"r" ~children:[
    Tree.node ~label:"l" ~children:[
      Tree.leaf ~label:"ll" ~value:1.0;
      Tree.leaf ~label:"lr" ~value:2.0;
    ];
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"rl" ~value:3.0;
      Tree.leaf ~label:"rr" ~value:4.0;
    ];
  ] in
  let deep2 = Tree.node ~label:"r" ~children:[
    Tree.node ~label:"l" ~children:[
      Tree.leaf ~label:"ll" ~value:1.0;
      Tree.leaf ~label:"lr" ~value:2.0;
    ];
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"rl" ~value:3.0;
      Tree.leaf ~label:"rr" ~value:5.0;
    ];
  ] in
  printf "Deep tree (one leaf +1): d=%.2f\n%!" (Distance.compute deep1 deep2);
  printf "Deep self: d=%.2f\n\n%!" (Distance.compute deep1 deep1);

  (* === Part 1: Rhode Island Hold'em === *)
  printf "--- Part 1: Rhode Island Hold'em (3-rank deck) ---\n\n%!";

  let config = Rhode_island.small_config ~n_ranks:3 in
  let deck = config.deck in
  printf "Deck (%d cards): %s\n%!"
    (List.length deck)
    (String.concat ~sep:", " (List.map deck ~f:Card.to_string));

  let p1a = List.nth_exn deck 0 in
  let p2a = List.nth_exn deck 1 in
  let flop = List.nth_exn deck 4 in
  let turn = List.nth_exn deck 8 in
  let community = [ flop; turn ] in

  printf "Community: %s, %s\n\n%!" (Card.to_string flop) (Card.to_string turn);

  let (tree_a, gen_time) = time (fun () ->
    Rhode_island.game_tree_for_deal ~config ~p1_card:p1a ~p2_card:p2a ~community) in
  printf "Deal A (%s vs %s): %d nodes, %d leaves, depth %d, EV=%.2f  (%.3fs)\n%!"
    (Card.to_string p1a) (Card.to_string p2a)
    (Tree.size tree_a) (Tree.num_leaves tree_a) (Tree.depth tree_a) (Tree.ev tree_a)
    gen_time;

  let p1b = List.nth_exn deck 2 in
  let p2b = List.nth_exn deck 3 in
  let tree_b = Rhode_island.game_tree_for_deal ~config ~p1_card:p1b ~p2_card:p2b ~community in
  printf "Deal B (%s vs %s): %d nodes, %d leaves, depth %d, EV=%.2f\n\n%!"
    (Card.to_string p1b) (Card.to_string p2b)
    (Tree.size tree_b) (Tree.num_leaves tree_b) (Tree.depth tree_b) (Tree.ev tree_b);

  let (dist, dt) = time (fun () -> Distance.compute tree_a tree_b) in
  printf "Distance(A,B): %.4f  (%.3fs)\n%!" dist dt;

  let (sd, sdt) = time (fun () -> Distance.compute tree_a tree_a) in
  printf "Self-distance: %.4f  (%.3fs)\n\n%!" sd sdt;

  (* === Part 2: Merge & error bound === *)
  printf "--- Part 2: Merge & error bound ---\n\n%!";
  let merged = Merge.merge ~config:Merge.default_config tree_a tree_b in
  let ev_a = Tree.ev tree_a in
  let ev_b = Tree.ev tree_b in
  let ev_m = Tree.ev merged in
  printf "EV(A)=%.4f  EV(B)=%.4f  EV(merged)=%.4f\n%!" ev_a ev_b ev_m;
  printf "Error from A: %.4f   Error from B: %.4f\n%!"
    (Float.abs (ev_m -. ev_a)) (Float.abs (ev_m -. ev_b));
  printf "Distance/2: %.4f  (bound on max single-side EV error)\n\n%!" (dist /. 2.0);

  (* === Part 3: Pairwise distance matrix === *)
  printf "--- Part 3: Pairwise distances ---\n\n%!";

  let remaining = List.filter deck ~f:(fun c ->
    not (Card.equal c flop) && not (Card.equal c turn))
  in
  let pairs = ref [] in
  List.iteri remaining ~f:(fun i c1 ->
    List.iteri remaining ~f:(fun j c2 ->
      match j > i && List.length !pairs < 8 with
      | true -> pairs := (c1, c2) :: !pairs
      | false -> ()));
  let pairs = List.rev !pairs in

  let deal_trees = List.map pairs ~f:(fun (p1, p2) ->
    let t = Rhode_island.game_tree_for_deal ~config ~p1_card:p1 ~p2_card:p2 ~community in
    ((p1, p2), t))
  in

  let n = List.length deal_trees in
  printf "%d deals, community=%s,%s:\n%!"
    n (Card.to_string flop) (Card.to_string turn);
  List.iter deal_trees ~f:(fun ((p1, p2), t) ->
    printf "  %s vs %s: %d nodes, EV=%+.1f\n%!"
      (Card.to_string p1) (Card.to_string p2) (Tree.size t) (Tree.ev t));

  printf "\nDistance matrix:\n%!";
  printf "          ";
  List.iter deal_trees ~f:(fun ((p1, p2), _) ->
    printf "%8s" (Card.to_string p1 ^ Card.to_string p2));
  printf "\n%!";

  let ((), dt) = time (fun () ->
    List.iteri deal_trees ~f:(fun i ((p1i, p2i), ti) ->
      printf "%4s%4s  " (Card.to_string p1i) (Card.to_string p2i);
      List.iteri deal_trees ~f:(fun j (_, tj) ->
        match i <= j with
        | true -> printf "%8.1f" (Distance.compute ti tj)
        | false -> printf "       .");
      printf "\n%!"))
  in
  printf "Matrix time: %.3fs\n\n%!" dt;

  (* === Part 4: Metric properties === *)
  printf "--- Part 4: Metric verification ---\n\n%!";
  (match n >= 3 with
   | true ->
     let t0 = snd (List.nth_exn deal_trees 0) in
     let t1 = snd (List.nth_exn deal_trees 1) in
     let t2 = snd (List.nth_exn deal_trees 2) in
     printf "Identity:  d(t0,t0)=%.6f  %s\n%!"
       (Distance.compute t0 t0)
       (match Float.( = ) (Distance.compute t0 t0) 0.0 with true -> "PASS" | false -> "FAIL");
     let d01 = Distance.compute t0 t1 in
     let d10 = Distance.compute t1 t0 in
     printf "Symmetry:  d(0,1)=%.4f  d(1,0)=%.4f  %s\n%!" d01 d10
       (match Float.( = ) d01 d10 with true -> "PASS" | false -> "FAIL");
     let d02 = Distance.compute t0 t2 in
     let d12 = Distance.compute t1 t2 in
     printf "Triangle:  d(0,2)=%.4f <= d(0,1)+d(1,2)=%.4f  %s\n%!"
       d02 (d01 +. d12)
       (match Float.( <= ) d02 (d01 +. d12 +. 0.001) with
        | true -> "PASS" | false -> "FAIL");
   | false -> printf "(need >= 3 deals)\n%!");

  printf "\nDone.\n"
