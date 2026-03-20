open! Core

let float_eq ?(eps = 1e-9) a b = Float.( < ) (Float.abs (a -. b)) eps

(* Helper: sort assignments for deterministic comparison *)
let sort_assignments assignments =
  List.sort assignments ~compare:(fun (r1, _) (r2, _) -> Int.compare r1 r2)

(* ---- 1x1 matrix ---- *)
let%test_unit "hungarian_1x1" =
  let cost = [| [| 5.0 |] |] in
  let result = Hungarian.solve cost in
  [%test_eq: (int * int) list] (sort_assignments result.assignments) [ (0, 0) ];
  assert (float_eq result.cost 5.0)

(* ---- 2x2 square ---- *)
let%test_unit "hungarian_2x2_identity" =
  (* Diagonal zeros: optimal = assign (0,0) and (1,1) *)
  let cost = [| [| 0.0; 1.0 |]; [| 1.0; 0.0 |] |] in
  let result = Hungarian.solve cost in
  [%test_eq: (int * int) list]
    (sort_assignments result.assignments)
    [ (0, 0); (1, 1) ];
  assert (float_eq result.cost 0.0)

let%test_unit "hungarian_2x2_swap" =
  (* Off-diagonal cheaper: optimal = assign (0,1) and (1,0) *)
  let cost = [| [| 10.0; 1.0 |]; [| 1.0; 10.0 |] |] in
  let result = Hungarian.solve cost in
  [%test_eq: (int * int) list]
    (sort_assignments result.assignments)
    [ (0, 1); (1, 0) ];
  assert (float_eq result.cost 2.0)

let%test_unit "hungarian_2x2_uniform" =
  (* All costs equal: any assignment, cost = 2 * 3.0 = 6.0 *)
  let cost = [| [| 3.0; 3.0 |]; [| 3.0; 3.0 |] |] in
  let result = Hungarian.solve cost in
  assert (float_eq result.cost 6.0);
  assert (List.length result.assignments = 2)

(* ---- 3x3 square ---- *)
let%test_unit "hungarian_3x3_known" =
  (* Classic example:
     [1 2 3]
     [2 4 6]
     [3 6 9]
     Optimal: (0,2)=3, (1,1)=4, (2,0)=3 => cost=10
     Or: (0,0)=1, (1,1)=4, (2,2)=9 => cost=14 ... not optimal
     Let's verify: (0,2)=3, (1,0)=2, (2,1)=6 => cost=11
     Actually: (0,0)=1, (1,2)=6, (2,1)=6 => cost=13
     (0,1)=2, (1,0)=2, (2,2)=9 => cost=13
     (0,1)=2, (1,2)=6, (2,0)=3 => cost=11
     (0,2)=3, (1,0)=2, (2,1)=6 => cost=11
     (0,2)=3, (1,1)=4, (2,0)=3 => cost=10
     So optimal = 10 *)
  let cost = [| [| 1.0; 2.0; 3.0 |]; [| 2.0; 4.0; 6.0 |]; [| 3.0; 6.0; 9.0 |] |] in
  let result = Hungarian.solve cost in
  assert (float_eq result.cost 10.0)

let%test_unit "hungarian_3x3_identity_matrix" =
  (* Identity matrix: diag=0, off-diag=1. Optimal = all diagonal, cost = 0 *)
  let cost = [| [| 0.0; 1.0; 1.0 |]; [| 1.0; 0.0; 1.0 |]; [| 1.0; 1.0; 0.0 |] |] in
  let result = Hungarian.solve cost in
  [%test_eq: (int * int) list]
    (sort_assignments result.assignments)
    [ (0, 0); (1, 1); (2, 2) ];
  assert (float_eq result.cost 0.0)

let%test_unit "hungarian_3x3_asymmetric" =
  (* Asymmetric cost matrix with known solution:
     [10  5  13]
     [ 3  7  15]
     [ 6  9  11]
     Possible: (0,1)=5, (1,0)=3, (2,2)=11 => 19
     (0,0)=10, (1,1)=7, (2,2)=11 => 28
     (0,2)=13, (1,0)=3, (2,1)=9 => 25
     (0,1)=5, (1,2)=15, (2,0)=6 => 26
     (0,2)=13, (1,1)=7, (2,0)=6 => 26
     (0,0)=10, (1,2)=15, (2,1)=9 => 34
     Optimal: (0,1)=5, (1,0)=3, (2,2)=11 => 19 *)
  let cost = [| [| 10.0; 5.0; 13.0 |]; [| 3.0; 7.0; 15.0 |]; [| 6.0; 9.0; 11.0 |] |] in
  let result = Hungarian.solve cost in
  assert (float_eq result.cost 19.0)

(* ---- 4x4 square ---- *)
let%test_unit "hungarian_4x4_known" =
  (* Classic 4x4 example from textbooks:
     [ 82 83 69 92 ]
     [ 77 37 49 92 ]
     [ 11 69  5 86 ]
     [  8  9 98 23 ]
     Optimal: (0,2)=69, (1,1)=37, (2,0)=11, (3,3)=23 => 140 *)
  let cost =
    [| [| 82.0; 83.0; 69.0; 92.0 |]
     ; [| 77.0; 37.0; 49.0; 92.0 |]
     ; [| 11.0; 69.0;  5.0; 86.0 |]
     ; [|  8.0;  9.0; 98.0; 23.0 |]
    |]
  in
  let result = Hungarian.solve cost in
  (* Multiple optima exist. Let's just verify cost *)
  assert (float_eq result.cost 140.0)

(* ---- Zero-cost matrix ---- *)
let%test_unit "hungarian_zero_cost" =
  let cost = [| [| 0.0; 0.0 |]; [| 0.0; 0.0 |] |] in
  let result = Hungarian.solve cost in
  assert (float_eq result.cost 0.0);
  assert (List.length result.assignments = 2)

let%test_unit "hungarian_zero_cost_3x3" =
  let cost =
    [| [| 0.0; 0.0; 0.0 |]; [| 0.0; 0.0; 0.0 |]; [| 0.0; 0.0; 0.0 |] |]
  in
  let result = Hungarian.solve cost in
  assert (float_eq result.cost 0.0);
  assert (List.length result.assignments = 3)

(* ---- Empty matrix ---- *)
let%test_unit "hungarian_empty" =
  let cost = [| |] in
  let result = Hungarian.solve cost in
  [%test_eq: (int * int) list] result.assignments [];
  assert (float_eq result.cost 0.0)

(* ---- Rectangular: more rows than cols ---- *)
let%test_unit "hungarian_rect_3x2" =
  (* 3 rows, 2 cols. Must pick 2 rows to match; 1 row gets phantom.
     [ 1  4 ]
     [ 2  3 ]
     [ 5  6 ]
     Phantom cost for all rows = 10.0
     Best real matching: (0,0)=1, (1,1)=3 => cost = 4 + phantom(row 2) = 14
     or (0,1)=4, (1,0)=2 => cost = 6 + phantom(row 2) = 16
     or (0,0)=1, (2,1)=6 => 7 + phantom(row 1) = 17
     So optimal = (0,0)=1, (1,1)=3, row 2 unmatched => real cost = 1+3 = 4, phantom = 10 => total = 14
  *)
  let cost = [| [| 1.0; 4.0 |]; [| 2.0; 3.0 |]; [| 5.0; 6.0 |] |] in
  let result =
    Hungarian.solve_rectangular cost
      ~phantom_cost_row:(fun _ -> 10.0)
      ~phantom_cost_col:(fun _ -> 10.0)
  in
  (* Only 2 assignments (real matches) *)
  assert (List.length result.assignments = 2);
  assert (float_eq result.cost 14.0)

(* ---- Rectangular: more cols than rows ---- *)
let%test_unit "hungarian_rect_2x3" =
  (* 2 rows, 3 cols. Must pick 2 cols to match; 1 col gets phantom.
     [ 1  4  2 ]
     [ 3  5  1 ]
     Phantom cost = 10.0
     Possible: (0,0)=1, (1,2)=1 => cost = 2 + phantom(col 1) = 12
     (0,2)=2, (1,0)=3 => 5 + phantom(col 1) = 15
     Optimal: (0,0)=1, (1,2)=1 => total = 12
  *)
  let cost = [| [| 1.0; 4.0; 2.0 |]; [| 3.0; 5.0; 1.0 |] |] in
  let result =
    Hungarian.solve_rectangular cost
      ~phantom_cost_row:(fun _ -> 10.0)
      ~phantom_cost_col:(fun _ -> 10.0)
  in
  assert (List.length result.assignments = 2);
  assert (float_eq result.cost 12.0)

(* ---- Rectangular: single row ---- *)
let%test_unit "hungarian_rect_1x3" =
  (* 1 row, 3 cols. Pick cheapest col, 2 cols get phantoms.
     [ 7  2  5 ]
     Phantom cost col = 3.0
     Best: (0,1)=2 + phantom(col 0)=3 + phantom(col 2)=3 = 8
  *)
  let cost = [| [| 7.0; 2.0; 5.0 |] |] in
  let result =
    Hungarian.solve_rectangular cost
      ~phantom_cost_row:(fun _ -> 100.0)
      ~phantom_cost_col:(fun _ -> 3.0)
  in
  assert (List.length result.assignments = 1);
  assert (float_eq result.cost 8.0)

(* ---- Rectangular: single col ---- *)
let%test_unit "hungarian_rect_3x1" =
  (* 3 rows, 1 col. Pick cheapest row.
     [| [| 5.0 |]; [| 1.0 |]; [| 9.0 |] |]
     Phantom cost row = 4.0
     Best: (1,0)=1, phantom(row 0)=4, phantom(row 2)=4 => 9
  *)
  let cost = [| [| 5.0 |]; [| 1.0 |]; [| 9.0 |] |] in
  let result =
    Hungarian.solve_rectangular cost
      ~phantom_cost_row:(fun _ -> 4.0)
      ~phantom_cost_col:(fun _ -> 100.0)
  in
  assert (List.length result.assignments = 1);
  assert (float_eq result.cost 9.0)

(* ---- Rectangular: square input should match solve ---- *)
let%test_unit "hungarian_rect_square_same_as_solve" =
  let cost = [| [| 10.0; 5.0 |]; [| 3.0; 7.0 |] |] in
  let r1 = Hungarian.solve cost in
  let r2 =
    Hungarian.solve_rectangular cost
      ~phantom_cost_row:(fun _ -> 1000.0)
      ~phantom_cost_col:(fun _ -> 1000.0)
  in
  assert (float_eq r1.cost r2.cost);
  [%test_eq: (int * int) list]
    (sort_assignments r1.assignments)
    (sort_assignments r2.assignments)

(* ---- Rectangular: empty ---- *)
let%test_unit "hungarian_rect_empty" =
  let cost = [| |] in
  let result =
    Hungarian.solve_rectangular cost
      ~phantom_cost_row:(fun _ -> 1.0)
      ~phantom_cost_col:(fun _ -> 1.0)
  in
  [%test_eq: (int * int) list] result.assignments [];
  assert (float_eq result.cost 0.0)

(* ---- Assignment validity ---- *)
let%test_unit "hungarian_assignment_validity" =
  (* Each row appears at most once, each col appears at most once *)
  let cost =
    [| [| 1.0; 2.0; 3.0; 4.0 |]
     ; [| 5.0; 6.0; 7.0; 8.0 |]
     ; [| 9.0; 1.0; 2.0; 3.0 |]
     ; [| 4.0; 5.0; 6.0; 7.0 |]
    |]
  in
  let result = Hungarian.solve cost in
  let rows = List.map result.assignments ~f:fst in
  let cols = List.map result.assignments ~f:snd in
  (* All rows distinct *)
  [%test_eq: int] (List.length (List.dedup_and_sort rows ~compare:Int.compare)) 4;
  (* All cols distinct *)
  [%test_eq: int] (List.length (List.dedup_and_sort cols ~compare:Int.compare)) 4;
  (* Cost matches sum of assigned entries *)
  let recomputed =
    List.sum (module Float) result.assignments ~f:(fun (r, c) -> cost.(r).(c))
  in
  assert (float_eq result.cost recomputed)

(* ---- Large-ish random consistency check ---- *)
let%test_unit "hungarian_cost_nonneg" =
  (* For a matrix of non-negative costs, total cost should be non-negative *)
  let n = 6 in
  let cost =
    Array.init n ~f:(fun i ->
      Array.init n ~f:(fun j ->
        Float.of_int ((i * 7 + j * 13 + 3) % 20)))
  in
  let result = Hungarian.solve cost in
  assert (Float.( >= ) result.cost 0.0);
  assert (List.length result.assignments = n)

(* ---- Symmetry ---- *)
let%test_unit "hungarian_symmetry" =
  (* Transposing the cost matrix should give the same total cost *)
  let cost = [| [| 2.0; 9.0; 4.0 |]; [| 7.0; 5.0; 3.0 |]; [| 6.0; 1.0; 8.0 |] |] in
  let transposed =
    Array.init 3 ~f:(fun i -> Array.init 3 ~f:(fun j -> cost.(j).(i)))
  in
  let r1 = Hungarian.solve cost in
  let r2 = Hungarian.solve transposed in
  assert (float_eq r1.cost r2.cost)
