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

(** Structural hashing: captures tree shape + leaf values, ignores labels.
    Quantizes floats to avoid floating-point hash instability. *)
let rec structural_hash : type a. a Tree.t -> int = fun tree ->
  match tree with
  | Leaf { value; _ } ->
    (* Quantize to 0.01 resolution to avoid floating point noise *)
    let q = Float.iround_nearest_exn (value *. 100.0) in
    Hashtbl.hash (0, q)
  | Node { children; _ } ->
    let child_hashes = List.map children ~f:structural_hash in
    (* Sort child hashes so unordered children produce the same hash *)
    let sorted = List.sort child_hashes ~compare:Int.compare in
    let n = List.length sorted in
    Hashtbl.hash (1, n, sorted)

module Memo = struct
  type memo_stats = {
    hits : int;
    misses : int;
  } [@@deriving sexp]

  let cache : (int * int, float) Hashtbl.t = Hashtbl.Poly.create ~size:1024 ()
  let memo_hits = ref 0
  let memo_misses = ref 0

  let clear () =
    Hashtbl.clear cache;
    memo_hits := 0;
    memo_misses := 0

  let stats () =
    { hits = !memo_hits; misses = !memo_misses }
end

let rec compute_memoized_impl config (t1 : 'a Tree.t) (t2 : 'a Tree.t) : float =
  let h1 = structural_hash t1 in
  let h2 = structural_hash t2 in
  (* Canonical key: always put smaller hash first for symmetry *)
  let key =
    match h1 <= h2 with
    | true -> (h1, h2)
    | false -> (h2, h1)
  in
  match Hashtbl.find Memo.cache key with
  | Some d ->
    Memo.memo_hits := !(Memo.memo_hits) + 1;
    d
  | None ->
    Memo.memo_misses := !(Memo.memo_misses) + 1;
    let d =
      match t1, t2 with
      | Leaf { value = v1; _ }, Leaf { value = v2; _ } ->
        config.leaf_distance v1 v2
      | Leaf _, Node _ ->
        let leaf_as_ev = Tree.ev t1 in
        let node_ev = Tree.ev t2 in
        Float.abs (leaf_as_ev -. node_ev) +. phantom_cost config t2
      | Node _, Leaf _ ->
        compute_memoized_impl config t2 t1
      | Node { children = c1; _ }, Node { children = c2; _ } ->
        let n1 = List.length c1 in
        let n2 = List.length c2 in
        match n1, n2 with
        | 0, 0 -> 0.0
        | 0, _ ->
          List.sum (module Float) c2 ~f:(phantom_cost config)
        | _, 0 ->
          List.sum (module Float) c1 ~f:(phantom_cost config)
        | _, _ ->
          let a1 = Array.of_list c1 in
          let a2 = Array.of_list c2 in
          let cost_matrix = Array.init n1 ~f:(fun i ->
            Array.init n2 ~f:(fun j ->
              compute_memoized_impl config a1.(i) a2.(j)))
          in
          let result = Hungarian.solve_rectangular cost_matrix
            ~phantom_cost_row:(fun i -> phantom_cost config a1.(i))
            ~phantom_cost_col:(fun j -> phantom_cost config a2.(j))
          in
          result.cost
    in
    Hashtbl.set Memo.cache ~key ~data:d;
    d

let compute_memoized t1 t2 =
  compute_memoized_impl default_config t1 t2

(** Depth-truncated RBM distance: recurse normally until [max_depth], then
    compare subtrees by |EV(T1) - EV(T2)| only.  This gives a LOWER BOUND
    on the full distance because the EV comparison is cheaper than the full
    recursive matching. *)
let rec compute_truncated_impl config ~max_depth ~depth
    (t1 : 'a Tree.t) (t2 : 'a Tree.t) : float =
  (* At or beyond max_depth: fall back to EV difference *)
  match depth >= max_depth with
  | true -> Float.abs (Tree.ev t1 -. Tree.ev t2)
  | false ->
    match t1, t2 with
    | Leaf { value = v1; _ }, Leaf { value = v2; _ } ->
      config.leaf_distance v1 v2
    | Leaf _, Node _ ->
      let leaf_as_ev = Tree.ev t1 in
      let node_ev = Tree.ev t2 in
      Float.abs (leaf_as_ev -. node_ev) +. phantom_cost config t2
    | Node _, Leaf _ ->
      compute_truncated_impl config ~max_depth ~depth t2 t1
    | Node { children = c1; _ }, Node { children = c2; _ } ->
      let n1 = List.length c1 in
      let n2 = List.length c2 in
      match n1, n2 with
      | 0, 0 -> 0.0
      | 0, _ ->
        List.sum (module Float) c2 ~f:(phantom_cost config)
      | _, 0 ->
        List.sum (module Float) c1 ~f:(phantom_cost config)
      | _, _ ->
        let a1 = Array.of_list c1 in
        let a2 = Array.of_list c2 in
        let cost_matrix = Array.init n1 ~f:(fun i ->
          Array.init n2 ~f:(fun j ->
            compute_truncated_impl config ~max_depth ~depth:(depth + 1)
              a1.(i) a2.(j)))
        in
        let result = Hungarian.solve_rectangular cost_matrix
          ~phantom_cost_row:(fun i -> phantom_cost config a1.(i))
          ~phantom_cost_col:(fun j -> phantom_cost config a2.(j))
        in
        result.cost

let compute_truncated ?(config = default_config) ~max_depth t1 t2 =
  compute_truncated_impl config ~max_depth ~depth:0 t1 t2

let compute_progressive ?(config = default_config) ~threshold t1 t2 =
  (* Depth 2: very cheap lower bound *)
  let d2 = compute_truncated_impl config ~max_depth:2 ~depth:0 t1 t2 in
  match Float.( > ) d2 threshold with
  | true -> (d2, 2)
  | false ->
    (* Depth 4: moderate cost, tighter lower bound *)
    let d4 = compute_truncated_impl config ~max_depth:4 ~depth:0 t1 t2 in
    match Float.( > ) d4 threshold with
    | true -> (d4, 4)
    | false ->
      (* Full depth: exact distance *)
      let d_full = compute_with_config ~config t1 t2 in
      (d_full, Int.max_value)
