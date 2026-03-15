type 'a cluster = {
  representative : 'a Tree.t;
  members : (int * 'a Tree.t) list;
  diameter : float;
}

type 'a t = {
  clusters : 'a cluster list;
  epsilon : float;
  compression_ratio : float;
}

type dist_matrix = float array array

let precompute_distances ?(distance_config = Distance.default_config) (trees : 'a Tree.t list) =
  let n = List.length trees in
  let tree_arr = Array.of_list trees in
  let dist = Array.init n ~f:(fun i ->
    Array.init n ~f:(fun j ->
      match i <= j with
      | true ->
        Distance.compute_with_config ~config:distance_config tree_arr.(i) tree_arr.(j)
      | false -> 0.0))
  in
  for i = 0 to n - 1 do
    for j = 0 to i - 1 do
      dist.(i).(j) <- dist.(j).(i)
    done
  done;
  dist

let compress ~epsilon ?(distance_config = Distance.default_config) ?precomputed (trees : 'a Tree.t list) =
  let n = List.length trees in
  let tree_arr = Array.of_list trees in
  let dist = match precomputed with
    | Some d -> d
    | None -> precompute_distances ~distance_config trees
  in

  (* Cluster assignments: cluster_of.(i) = which cluster tree i belongs to *)
  let cluster_of = Array.init n ~f:Fn.id in
  let active = Array.create ~len:n true in (* which clusters are still active *)

  let merge_config = { Merge.phantom_policy = Drop; distance_config } in

  (* Cluster data *)
  let reps = Array.map tree_arr ~f:Fn.id in
  let members = Array.init n ~f:(fun i -> [ (i, tree_arr.(i)) ]) in
  let diameters = Array.create ~len:n 0.0 in

  let continue = ref true in
  while !continue do
    (* Find closest pair of active clusters using single-linkage:
       min distance between any member of cluster i and any member of cluster j *)
    let best_dist = ref Float.infinity in
    let best_ci = ref (-1) in
    let best_cj = ref (-1) in
    for ci = 0 to n - 1 do
      match active.(ci) with
      | false -> ()
      | true ->
        for cj = ci + 1 to n - 1 do
          match active.(cj) with
          | false -> ()
          | true ->
            (* Single-linkage: min distance between any pair of members *)
            let min_d = ref Float.infinity in
            List.iter members.(ci) ~f:(fun (mi, _) ->
              List.iter members.(cj) ~f:(fun (mj, _) ->
                let d = dist.(mi).(mj) in
                (match Float.( < ) d !min_d with
                 | true -> min_d := d
                 | false -> ())));
            (match Float.( < ) !min_d !best_dist with
             | true -> best_dist := !min_d; best_ci := ci; best_cj := cj
             | false -> ())
        done
    done;

    match Float.( <= ) !best_dist epsilon && !best_ci >= 0 with
    | true ->
      let ci = !best_ci in
      let cj = !best_cj in
      (* Merge cj into ci *)
      let w1 = Float.of_int (List.length members.(ci)) in
      let w2 = Float.of_int (List.length members.(cj)) in
      reps.(ci) <- Merge.merge_weighted ~config:merge_config
          ~w1 ~w2 reps.(ci) reps.(cj);
      members.(ci) <- members.(ci) @ members.(cj);
      diameters.(ci) <- Float.max (Float.max diameters.(ci) diameters.(cj)) !best_dist;
      (* Update cluster assignments *)
      List.iter members.(cj) ~f:(fun (idx, _) -> cluster_of.(idx) <- ci);
      active.(cj) <- false
    | false ->
      continue := false
  done;

  let clusters = Array.to_list (Array.filter_mapi active ~f:(fun i is_active ->
    match is_active with
    | true ->
      Some { representative = reps.(i); members = members.(i); diameter = diameters.(i) }
    | false -> None))
  in
  let num_clusters = List.length clusters in
  { clusters
  ; epsilon
  ; compression_ratio = Float.of_int n /. Float.of_int (Int.max 1 num_clusters)
  }

let find_cluster ?(distance_config = Distance.default_config) graph tree =
  let distances = List.mapi graph.clusters ~f:(fun i c ->
    let d = Distance.compute_with_config ~config:distance_config
        tree c.representative in
    (i, d))
  in
  List.fold distances ~init:(0, Float.infinity) ~f:(fun (best_i, best_d) (i, d) ->
    match Float.( < ) d best_d with
    | true -> (i, d)
    | false -> (best_i, best_d))

let ev_error graph =
  List.fold graph.clusters ~init:0.0 ~f:(fun acc cluster ->
    let rep_ev = Tree.ev cluster.representative in
    let max_err = List.fold cluster.members ~init:0.0 ~f:(fun acc (_, t) ->
      Float.max acc (Float.abs (Tree.ev t -. rep_ev)))
    in
    Float.max acc max_err)

let report graph =
  let num_clusters = List.length graph.clusters in
  let total_members = List.sum (module Int) graph.clusters
      ~f:(fun c -> List.length c.members) in
  let max_diameter = List.fold graph.clusters ~init:0.0
      ~f:(fun acc c -> Float.max acc c.diameter) in
  let ev_err = ev_error graph in
  sprintf "EV Graph: %d trees -> %d clusters (%.1fx compression)\n\
           epsilon=%.2f  max_diameter=%.2f  max_ev_error=%.4f"
    total_members num_clusters graph.compression_ratio
    graph.epsilon max_diameter ev_err
