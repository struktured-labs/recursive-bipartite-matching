type 'a t =
  | Leaf of { value : float; label : 'a }
  | Node of { children : 'a t list; label : 'a }
[@@deriving sexp, compare]

let leaf ~label ~value = Leaf { value; label }
let node ~label ~children = Node { children; label }

let rec size = function
  | Leaf _ -> 1
  | Node { children; _ } ->
    1 + List.sum (module Int) children ~f:size

let rec depth = function
  | Leaf _ -> 0
  | Node { children; _ } ->
    match children with
    | [] -> 0
    | _ -> 1 + List.fold children ~init:0 ~f:(fun acc c -> Int.max acc (depth c))

let rec num_leaves = function
  | Leaf _ -> 1
  | Node { children; _ } ->
    List.sum (module Int) children ~f:num_leaves

let rec map_label t ~f =
  match t with
  | Leaf { value; label } -> Leaf { value; label = f label }
  | Node { children; label } ->
    Node { children = List.map children ~f:(map_label ~f); label = f label }

let rec fold_leaves t ~init ~f =
  match t with
  | Leaf { value; _ } -> f init value
  | Node { children; _ } ->
    List.fold children ~init ~f:(fun acc c -> fold_leaves c ~init:acc ~f)

let ev t =
  let sum, count =
    fold_leaves t ~init:(0.0, 0) ~f:(fun (s, c) v -> (s +. v, c + 1))
  in
  match count with
  | 0 -> 0.0
  | n -> sum /. Float.of_int n
