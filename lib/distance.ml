type 'a t = 'a Tree.t

type leaf_distance_fn = float -> float -> float

let sexp_of_leaf_distance_fn _ = Sexp.Atom "<fn>"
let leaf_distance_fn_of_sexp _ = fun a b -> Float.abs (a -. b)

type config = {
  phantom_penalty : [ `Ev | `Size of float | `Constant of float ];
  leaf_distance : leaf_distance_fn;
} [@@deriving sexp]

let default_config =
  { phantom_penalty = `Ev
  ; leaf_distance = (fun a b -> Float.abs (a -. b))
  }

let phantom_cost config tree =
  match config.phantom_penalty with
  | `Ev -> Float.abs (Tree.ev tree)
  | `Size scale -> scale *. Float.of_int (Tree.size tree)
  | `Constant c -> c

let rec compute_impl config (t1 : 'a t) (t2 : 'a t) : float * (int * int) list =
  match t1, t2 with
  | Leaf { value = v1; _ }, Leaf { value = v2; _ } ->
    (config.leaf_distance v1 v2, [])
  | Leaf _, Node _ ->
    (* Leaf vs node: treat leaf as node with no children, all node's children
       match against phantoms *)
    let leaf_as_ev = Tree.ev t1 in
    let node_ev = Tree.ev t2 in
    (Float.abs (leaf_as_ev -. node_ev) +. phantom_cost config t2, [])
  | Node _, Leaf _ ->
    let d, m = compute_impl config t2 t1 in
    (d, List.map m ~f:(fun (a, b) -> (b, a)))
  | Node { children = c1; _ }, Node { children = c2; _ } ->
    let n1 = List.length c1 in
    let n2 = List.length c2 in
    match n1, n2 with
    | 0, 0 -> (0.0, [])
    | 0, _ ->
      let cost = List.sum (module Float) c2 ~f:(phantom_cost config) in
      (cost, [])
    | _, 0 ->
      let cost = List.sum (module Float) c1 ~f:(phantom_cost config) in
      (cost, [])
    | _, _ ->
      let a1 = Array.of_list c1 in
      let a2 = Array.of_list c2 in
      (* Build cost matrix: recursive distance between each pair *)
      let cost_matrix = Array.init n1 ~f:(fun i ->
        Array.init n2 ~f:(fun j ->
          let d, _ = compute_impl config a1.(i) a2.(j) in
          d))
      in
      let result = Hungarian.solve_rectangular cost_matrix
        ~phantom_cost_row:(fun i -> phantom_cost config a1.(i))
        ~phantom_cost_col:(fun j -> phantom_cost config a2.(j))
      in
      (result.cost, result.assignments)

let compute t1 t2 =
  let d, _ = compute_impl default_config t1 t2 in
  d

let compute_with_config ~config t1 t2 =
  let d, _ = compute_impl config t1 t2 in
  d

let compute_with_matching ~config t1 t2 =
  compute_impl config t1 t2
