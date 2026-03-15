type 'a t = 'a Tree.t

type phantom_policy =
  | Drop
  | Keep
[@@deriving sexp]

type config = {
  phantom_policy : phantom_policy;
  distance_config : Distance.config;
}

let default_config =
  { phantom_policy = Drop
  ; distance_config = Distance.default_config
  }

let merge_leaves ~w1 ~w2 v1 v2 =
  (w1 *. v1 +. w2 *. v2) /. (w1 +. w2)

let rec merge_impl ~config ~w1 ~w2 (t1 : 'a t) (t2 : 'a t) : 'a t =
  match t1, t2 with
  | Leaf { value = v1; label }, Leaf { value = v2; _ } ->
    Leaf { value = merge_leaves ~w1 ~w2 v1 v2; label }
  | Leaf _, Node { label; _ } ->
    (* Leaf vs node: use the node's structure with blended values *)
    Tree.map_label t2 ~f:(fun _ -> label)
  | Node { label; _ }, Leaf _ ->
    Tree.map_label t1 ~f:(fun _ -> label)
  | Node { children = c1; label }, Node { children = c2; _ } ->
    let _, matching =
      Distance.compute_with_matching ~config:config.distance_config t1 t2
    in
    let a1 = Array.of_list c1 in
    let a2 = Array.of_list c2 in
    let n1 = Array.length a1 in
    let n2 = Array.length a2 in
    let matched_rows = Set.of_list (module Int) (List.map matching ~f:fst) in
    let matched_cols = Set.of_list (module Int) (List.map matching ~f:snd) in
    (* Recursively merge matched pairs *)
    let merged_children =
      List.map matching ~f:(fun (i, j) ->
        merge_impl ~config ~w1 ~w2 a1.(i) a2.(j))
    in
    (* Handle unmatched children based on policy *)
    let unmatched =
      match config.phantom_policy with
      | Drop -> []
      | Keep ->
        let unmatched_from_1 =
          List.init n1 ~f:Fn.id
          |> List.filter ~f:(fun i -> not (Set.mem matched_rows i))
          |> List.map ~f:(fun i -> a1.(i))
        in
        let unmatched_from_2 =
          List.init n2 ~f:Fn.id
          |> List.filter ~f:(fun j -> not (Set.mem matched_cols j))
          |> List.map ~f:(fun j -> a2.(j))
        in
        unmatched_from_1 @ unmatched_from_2
    in
    Node { children = merged_children @ unmatched; label }

let merge ~config t1 t2 = merge_impl ~config ~w1:1.0 ~w2:1.0 t1 t2
let merge_weighted ~config ~w1 ~w2 t1 t2 = merge_impl ~config ~w1 ~w2 t1 t2
