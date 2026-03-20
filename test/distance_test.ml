open! Core

let float_eq ?(eps = 1e-9) a b = Float.( < ) (Float.abs (a -. b)) eps

(* ---- Identical trees => distance 0 ---- *)
let%test_unit "distance_identical_leaves" =
  let t = Tree.leaf ~label:"a" ~value:5.0 in
  assert (float_eq (Distance.compute t t) 0.0)

let%test_unit "distance_identical_nodes" =
  let t =
    Tree.node ~label:"root" ~children:[
      Tree.leaf ~label:"l" ~value:1.0;
      Tree.leaf ~label:"r" ~value:2.0;
    ]
  in
  assert (float_eq (Distance.compute t t) 0.0)

let%test_unit "distance_identical_deep" =
  let t =
    Tree.node ~label:"root" ~children:[
      Tree.node ~label:"a" ~children:[
        Tree.leaf ~label:"a1" ~value:1.0;
        Tree.leaf ~label:"a2" ~value:2.0;
      ];
      Tree.node ~label:"b" ~children:[
        Tree.leaf ~label:"b1" ~value:3.0;
        Tree.leaf ~label:"b2" ~value:4.0;
      ];
    ]
  in
  assert (float_eq (Distance.compute t t) 0.0)

(* ---- Two leaves with different values ---- *)
let%test_unit "distance_different_leaves" =
  let t1 = Tree.leaf ~label:"a" ~value:3.0 in
  let t2 = Tree.leaf ~label:"b" ~value:7.0 in
  (* Default leaf_distance = |v1 - v2| = 4.0 *)
  assert (float_eq (Distance.compute t1 t2) 4.0)

let%test_unit "distance_leaves_negative" =
  let t1 = Tree.leaf ~label:"a" ~value:(-2.0) in
  let t2 = Tree.leaf ~label:"b" ~value:3.0 in
  assert (float_eq (Distance.compute t1 t2) 5.0)

let%test_unit "distance_leaves_zero_diff" =
  let t1 = Tree.leaf ~label:"a" ~value:4.0 in
  let t2 = Tree.leaf ~label:"b" ~value:4.0 in
  assert (float_eq (Distance.compute t1 t2) 0.0)

(* ---- Symmetry ---- *)
let%test_unit "distance_symmetry" =
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:5.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:2.0;
      Tree.leaf ~label:"d" ~value:3.0;
    ]
  in
  let d12 = Distance.compute t1 t2 in
  let d21 = Distance.compute t2 t1 in
  assert (float_eq d12 d21)

(* ---- Simple 2-child nodes ---- *)
let%test_unit "distance_2child_exact_match" =
  (* Children match perfectly: (1,1) and (5,5) *)
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:5.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:1.0;
      Tree.leaf ~label:"d" ~value:5.0;
    ]
  in
  assert (float_eq (Distance.compute t1 t2) 0.0)

let%test_unit "distance_2child_optimal_assignment" =
  (* t1 children: 1.0, 10.0
     t2 children: 2.0, 9.0
     Matching (1->2, 10->9): cost = 1 + 1 = 2
     Matching (1->9, 10->2): cost = 8 + 8 = 16
     Optimal = 2 *)
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:10.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:2.0;
      Tree.leaf ~label:"d" ~value:9.0;
    ]
  in
  assert (float_eq (Distance.compute t1 t2) 2.0)

let%test_unit "distance_2child_swap_needed" =
  (* t1: [1, 10], t2: [11, 2]
     Match (1->11, 10->2): cost = 10+8 = 18
     Match (1->2, 10->11): cost = 1+1 = 2
     Optimal = 2 (swap alignment) *)
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:10.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:11.0;
      Tree.leaf ~label:"d" ~value:2.0;
    ]
  in
  assert (float_eq (Distance.compute t1 t2) 2.0)

(* ---- Phantom penalty: mismatched child counts ---- *)
let%test_unit "distance_phantom_ev_penalty" =
  (* t1: 2 children [1, 3], t2: 1 child [2]
     With `Ev phantom penalty:
     - Match child 2 with one of {1,3}
     - Unmatched child gets phantom cost = |EV(subtree)|
     Best: match 1->2 (cost=1), phantom for 3 = |3| = 3. Total = 4
     Or: match 3->2 (cost=1), phantom for 1 = |1| = 1. Total = 2
     Optimal = 2 *)
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:3.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:2.0;
    ]
  in
  assert (float_eq (Distance.compute t1 t2) 2.0)

let%test_unit "distance_phantom_constant_penalty" =
  (* Same setup but with constant penalty = 100 *)
  let config = { Distance.phantom_penalty = `Constant 100.0
               ; leaf_distance = (fun a b -> Float.abs (a -. b))
               } in
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:3.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:2.0;
    ]
  in
  (* Match 3->2 (cost=1), phantom for 1 = 100. Total = 101.
     Match 1->2 (cost=1), phantom for 3 = 100. Total = 101.
     Both = 101 *)
  assert (float_eq (Distance.compute_with_config ~config t1 t2) 101.0)

let%test_unit "distance_phantom_size_penalty" =
  (* With `Size 2.0 penalty: phantom cost = 2.0 * size(subtree) = 2.0 * 1 = 2.0 per leaf *)
  let config = { Distance.phantom_penalty = `Size 2.0
               ; leaf_distance = (fun a b -> Float.abs (a -. b))
               } in
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:3.0;
      Tree.leaf ~label:"c" ~value:5.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"d" ~value:2.0;
    ]
  in
  (* 3 vs 1: pick best 1 match, 2 get phantom at cost 2.0 each = 4.0
     Match 1->2: cost=1, phantoms for {3,5} = 2+2 = 4. Total=5
     Match 3->2: cost=1, phantoms for {1,5} = 2+2 = 4. Total=5
     Match 5->2: cost=3, phantoms for {1,3} = 2+2 = 4. Total=7
     Optimal = 5.0 *)
  assert (float_eq (Distance.compute_with_config ~config t1 t2) 5.0)

(* ---- Leaf vs Node ---- *)
let%test_unit "distance_leaf_vs_node" =
  (* Leaf(5) vs Node{children=[Leaf(3), Leaf(7)]}
     leaf EV = 5, node EV = (3+7)/2 = 5
     |EV diff| + phantom_cost(node)
     = |5-5| + |EV(node)| = 0 + 5 = 5 *)
  let t1 = Tree.leaf ~label:"a" ~value:5.0 in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"b" ~value:3.0;
      Tree.leaf ~label:"c" ~value:7.0;
    ]
  in
  assert (float_eq (Distance.compute t1 t2) 5.0)

let%test_unit "distance_node_vs_leaf_symmetric" =
  let t1 = Tree.leaf ~label:"a" ~value:5.0 in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"b" ~value:3.0;
      Tree.leaf ~label:"c" ~value:7.0;
    ]
  in
  let d12 = Distance.compute t1 t2 in
  let d21 = Distance.compute t2 t1 in
  assert (float_eq d12 d21)

(* ---- Recursive distance ---- *)
let%test_unit "distance_recursive_2level" =
  (* Two 2-level trees with identical structure, different leaf values *)
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.node ~label:"a" ~children:[
        Tree.leaf ~label:"a1" ~value:0.0;
        Tree.leaf ~label:"a2" ~value:2.0;
      ];
      Tree.node ~label:"b" ~children:[
        Tree.leaf ~label:"b1" ~value:4.0;
        Tree.leaf ~label:"b2" ~value:6.0;
      ];
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.node ~label:"c" ~children:[
        Tree.leaf ~label:"c1" ~value:1.0;
        Tree.leaf ~label:"c2" ~value:3.0;
      ];
      Tree.node ~label:"d" ~children:[
        Tree.leaf ~label:"d1" ~value:5.0;
        Tree.leaf ~label:"d2" ~value:7.0;
      ];
    ]
  in
  (* Children distances:
     a vs c: match (0->1, 2->3) cost = 1+1 = 2 vs (0->3, 2->1) cost = 3+1 = 4 => 2
     a vs d: match (0->5, 2->7) cost = 5+5 = 10 vs (0->7, 2->5) cost = 7+3 = 10 => 10
     b vs c: match (4->1, 6->3) cost = 3+3 = 6 vs (4->3, 6->1) cost = 1+5 = 6 => 6
     b vs d: match (4->5, 6->7) cost = 1+1 = 2 vs (4->7, 6->5) cost = 3+1 = 4 => 2
     Root assignment:
     (a->c, b->d): 2+2 = 4
     (a->d, b->c): 10+6 = 16
     Optimal = 4 *)
  assert (float_eq (Distance.compute t1 t2) 4.0)

(* ---- Triangle inequality sanity check ---- *)
let%test_unit "distance_triangle_inequality" =
  let t1 = Tree.leaf ~label:"a" ~value:0.0 in
  let t2 = Tree.leaf ~label:"b" ~value:5.0 in
  let t3 = Tree.leaf ~label:"c" ~value:8.0 in
  let d12 = Distance.compute t1 t2 in
  let d23 = Distance.compute t2 t3 in
  let d13 = Distance.compute t1 t3 in
  (* d13 <= d12 + d23 *)
  assert (Float.( <= ) d13 (d12 +. d23 +. 1e-9))

(* ---- Memoization ---- *)
let%test_unit "distance_memoized_same_as_regular" =
  Distance.Memo.clear ();
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:3.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:2.0;
      Tree.leaf ~label:"d" ~value:5.0;
    ]
  in
  let d_regular = Distance.compute t1 t2 in
  let d_memo = Distance.compute_memoized t1 t2 in
  assert (float_eq d_regular d_memo)

let%test_unit "distance_memoized_cache_hit" =
  Distance.Memo.clear ();
  let t1 = Tree.leaf ~label:"a" ~value:1.0 in
  let t2 = Tree.leaf ~label:"b" ~value:4.0 in
  let _ = Distance.compute_memoized t1 t2 in
  let stats1 = Distance.Memo.stats () in
  let _ = Distance.compute_memoized t1 t2 in
  let stats2 = Distance.Memo.stats () in
  (* Second call should be a cache hit *)
  [%test_eq: int] stats2.hits (stats1.hits + 1);
  [%test_eq: int] stats2.misses stats1.misses

(* ---- Truncated distance ---- *)
let%test_unit "distance_truncated_lower_bound" =
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.node ~label:"a" ~children:[
        Tree.leaf ~label:"a1" ~value:0.0;
        Tree.leaf ~label:"a2" ~value:10.0;
      ];
      Tree.node ~label:"b" ~children:[
        Tree.leaf ~label:"b1" ~value:5.0;
        Tree.leaf ~label:"b2" ~value:15.0;
      ];
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.node ~label:"c" ~children:[
        Tree.leaf ~label:"c1" ~value:1.0;
        Tree.leaf ~label:"c2" ~value:11.0;
      ];
      Tree.node ~label:"d" ~children:[
        Tree.leaf ~label:"d1" ~value:6.0;
        Tree.leaf ~label:"d2" ~value:16.0;
      ];
    ]
  in
  let d_full = Distance.compute t1 t2 in
  let d_trunc = Distance.compute_truncated ~max_depth:1 t1 t2 in
  (* Truncated should be <= full (it's a lower bound) *)
  assert (Float.( <= ) d_trunc (d_full +. 1e-9))

(* ---- Empty children nodes ---- *)
let%test_unit "distance_empty_children_nodes" =
  let t1 = Tree.node ~label:"r" ~children:[] in
  let t2 = Tree.node ~label:"r" ~children:[] in
  assert (float_eq (Distance.compute t1 t2) 0.0)

let%test_unit "distance_empty_vs_nonempty" =
  (* Node with no children vs node with children: all children are phantoms *)
  let t1 = Tree.node ~label:"r" ~children:[] in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:3.0;
    ]
  in
  (* phantom cost with `Ev = |EV(leaf 3)| = 3.0 *)
  assert (float_eq (Distance.compute t1 t2) 3.0)
