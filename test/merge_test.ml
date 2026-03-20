open! Core

let float_eq ?(eps = 1e-9) a b = Float.( < ) (Float.abs (a -. b)) eps

(* Helper to extract leaf value *)
let leaf_value = function
  | Tree.Leaf { value; _ } -> value
  | Tree.Node _ -> failwith "expected leaf"

let num_children = function
  | Tree.Leaf _ -> 0
  | Tree.Node { children; _ } -> List.length children

(* ---- Merge identical leaves ---- *)
let%test_unit "merge_identical_leaves" =
  let config = Merge.default_config in
  let t = Tree.leaf ~label:"a" ~value:5.0 in
  let merged = Merge.merge ~config t t in
  assert (float_eq (leaf_value merged) 5.0)

(* ---- Merge different leaves ---- *)
let%test_unit "merge_different_leaves_averaged" =
  let config = Merge.default_config in
  let t1 = Tree.leaf ~label:"a" ~value:2.0 in
  let t2 = Tree.leaf ~label:"b" ~value:8.0 in
  let merged = Merge.merge ~config t1 t2 in
  (* Equal weight average: (2+8)/2 = 5.0 *)
  assert (float_eq (leaf_value merged) 5.0)

let%test_unit "merge_weighted_leaves" =
  let config = Merge.default_config in
  let t1 = Tree.leaf ~label:"a" ~value:2.0 in
  let t2 = Tree.leaf ~label:"b" ~value:8.0 in
  let merged = Merge.merge_weighted ~config ~w1:3.0 ~w2:1.0 t1 t2 in
  (* Weighted avg: (3*2 + 1*8) / (3+1) = 14/4 = 3.5 *)
  assert (float_eq (leaf_value merged) 3.5)

(* ---- Merge identical trees ---- *)
let%test_unit "merge_identical_tree" =
  let config = Merge.default_config in
  let t =
    Tree.node ~label:"root" ~children:[
      Tree.leaf ~label:"l" ~value:1.0;
      Tree.leaf ~label:"r" ~value:3.0;
    ]
  in
  let merged = Merge.merge ~config t t in
  (* Merging identical tree with itself should preserve structure *)
  [%test_eq: int] (num_children merged) 2;
  (* EV should be preserved *)
  assert (float_eq (Tree.ev merged) (Tree.ev t))

(* ---- Merge with same structure, different values ---- *)
let%test_unit "merge_same_structure_diff_values" =
  let config = Merge.default_config in
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:0.0;
      Tree.leaf ~label:"b" ~value:10.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:2.0;
      Tree.leaf ~label:"d" ~value:8.0;
    ]
  in
  let merged = Merge.merge ~config t1 t2 in
  (* Should have 2 children *)
  [%test_eq: int] (num_children merged) 2;
  (* Average EV: original EV t1 = 5.0, t2 = 5.0, merged should be 5.0 *)
  assert (float_eq (Tree.ev merged) 5.0)

(* ---- Merge with phantoms: Drop policy ---- *)
let%test_unit "merge_phantom_drop" =
  let config =
    { Merge.phantom_policy = Drop
    ; distance_config = Distance.default_config
    }
  in
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:2.0;
      Tree.leaf ~label:"c" ~value:3.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"d" ~value:1.5;
    ]
  in
  let merged = Merge.merge ~config t1 t2 in
  (* Drop policy: only matched children survive.
     1 child from t2, matched with best from t1 => 1 child in result *)
  [%test_eq: int] (num_children merged) 1

(* ---- Merge with phantoms: Keep policy ---- *)
let%test_unit "merge_phantom_keep" =
  let config =
    { Merge.phantom_policy = Keep
    ; distance_config = Distance.default_config
    }
  in
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:2.0;
      Tree.leaf ~label:"c" ~value:3.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"d" ~value:1.5;
    ]
  in
  let merged = Merge.merge ~config t1 t2 in
  (* Keep policy: matched child (1) + unmatched from t1 (2) = 3 children *)
  [%test_eq: int] (num_children merged) 3

(* ---- Merge preserves label from first tree ---- *)
let%test_unit "merge_preserves_label" =
  let config = Merge.default_config in
  let t1 = Tree.leaf ~label:"first" ~value:1.0 in
  let t2 = Tree.leaf ~label:"second" ~value:2.0 in
  let merged = Merge.merge ~config t1 t2 in
  (match merged with
   | Tree.Leaf { label; _ } -> [%test_eq: string] label "first"
   | Tree.Node _ -> failwith "expected leaf")

(* ---- Merge recursive structure ---- *)
let%test_unit "merge_recursive_structure" =
  let config = Merge.default_config in
  let t1 =
    Tree.node ~label:"root" ~children:[
      Tree.node ~label:"a" ~children:[
        Tree.leaf ~label:"a1" ~value:0.0;
        Tree.leaf ~label:"a2" ~value:4.0;
      ];
      Tree.node ~label:"b" ~children:[
        Tree.leaf ~label:"b1" ~value:6.0;
        Tree.leaf ~label:"b2" ~value:10.0;
      ];
    ]
  in
  let t2 =
    Tree.node ~label:"root" ~children:[
      Tree.node ~label:"c" ~children:[
        Tree.leaf ~label:"c1" ~value:1.0;
        Tree.leaf ~label:"c2" ~value:5.0;
      ];
      Tree.node ~label:"d" ~children:[
        Tree.leaf ~label:"d1" ~value:7.0;
        Tree.leaf ~label:"d2" ~value:11.0;
      ];
    ]
  in
  let merged = Merge.merge ~config t1 t2 in
  (* Structure should be preserved: 2 children, each with 2 grandchildren *)
  [%test_eq: int] (num_children merged) 2;
  (match merged with
   | Tree.Node { children; _ } ->
     List.iter children ~f:(fun child ->
       [%test_eq: int] (num_children child) 2)
   | Tree.Leaf _ -> failwith "expected node")

(* ---- Merge weighted preserves weighted average ---- *)
let%test_unit "merge_weighted_structure" =
  let config = Merge.default_config in
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:10.0;
      Tree.leaf ~label:"b" ~value:20.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:30.0;
      Tree.leaf ~label:"d" ~value:40.0;
    ]
  in
  let merged = Merge.merge_weighted ~config ~w1:2.0 ~w2:3.0 t1 t2 in
  (* Both trees have EV = avg of leaves.
     t1: (10+20)/2 = 15, t2: (30+40)/2 = 35
     For each matched pair, value = (2*v1 + 3*v2)/(2+3)
     If matching is (10->30, 20->40):
       child1 = (20+90)/5 = 22, child2 = (40+120)/5 = 32
       EV = (22+32)/2 = 27
     Or if (10->40, 20->30):
       child1 = (20+120)/5 = 28, child2 = (40+90)/5 = 26
       EV = (28+26)/2 = 27
     Either way, EV = 27 = (2*15 + 3*35)/5 *)
  assert (float_eq (Tree.ev merged) 27.0)

(* ---- Merge leaf vs node ---- *)
let%test_unit "merge_leaf_vs_node" =
  let config = Merge.default_config in
  let t1 = Tree.leaf ~label:"l" ~value:5.0 in
  let t2 =
    Tree.node ~label:"n" ~children:[
      Tree.leaf ~label:"a" ~value:3.0;
      Tree.leaf ~label:"b" ~value:7.0;
    ]
  in
  (* Leaf vs node: uses node's structure with leaf's label *)
  let merged = Merge.merge ~config t1 t2 in
  (* Result should be a node (from t2's structure) *)
  (match merged with
   | Tree.Node _ -> ()
   | Tree.Leaf _ -> failwith "expected node when merging leaf vs node")

let%test_unit "merge_node_vs_leaf" =
  let config = Merge.default_config in
  let t1 =
    Tree.node ~label:"n" ~children:[
      Tree.leaf ~label:"a" ~value:3.0;
      Tree.leaf ~label:"b" ~value:7.0;
    ]
  in
  let t2 = Tree.leaf ~label:"l" ~value:5.0 in
  (* Node vs leaf: uses node's structure *)
  let merged = Merge.merge ~config t1 t2 in
  (match merged with
   | Tree.Node _ -> ()
   | Tree.Leaf _ -> failwith "expected node when merging node vs leaf")

(* ---- Merge empty children ---- *)
let%test_unit "merge_empty_children" =
  let config = Merge.default_config in
  let t1 = Tree.node ~label:"r" ~children:[] in
  let t2 = Tree.node ~label:"r" ~children:[] in
  let merged = Merge.merge ~config t1 t2 in
  [%test_eq: int] (num_children merged) 0

(* ---- Merge size preservation with Drop ---- *)
let%test_unit "merge_drop_equal_children" =
  let config =
    { Merge.phantom_policy = Drop
    ; distance_config = Distance.default_config
    }
  in
  let t1 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"a" ~value:1.0;
      Tree.leaf ~label:"b" ~value:2.0;
    ]
  in
  let t2 =
    Tree.node ~label:"r" ~children:[
      Tree.leaf ~label:"c" ~value:3.0;
      Tree.leaf ~label:"d" ~value:4.0;
    ]
  in
  let merged = Merge.merge ~config t1 t2 in
  (* Equal number of children, so all match. Drop doesn't remove any. *)
  [%test_eq: int] (num_children merged) 2
