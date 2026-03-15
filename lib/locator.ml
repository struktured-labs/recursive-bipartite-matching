type belief = {
  weights : (int * float) list;
  map_cluster : int;
  map_probability : float;
  entropy : float;
}

type config = {
  num_samples : int;
  sample_depth : int;
  beta : float;
  distance_config : Distance.config;
}

let default_config = {
  num_samples = 50;
  sample_depth = 4;
  beta = 1.0;
  distance_config = Distance.default_config;
}

let rec sample_subtree ~depth (tree : 'a Tree.t) : 'a Tree.t =
  match depth with
  | 0 ->
    (* At max depth, collapse to a leaf with the subtree's EV *)
    Tree.leaf ~label:(match tree with
      | Leaf { label; _ } -> label
      | Node { label; _ } -> label)
      ~value:(Tree.ev tree)
  | _ ->
    (match tree with
     | Leaf _ -> tree
     | Node { children = []; label } ->
       Tree.leaf ~label ~value:0.0
     | Node { children; label } ->
       (* Pick a random child and recurse *)
       let idx = Random.int (List.length children) in
       let child = List.nth_exn children idx in
       let sampled_child = sample_subtree ~depth:(depth - 1) child in
       (* Return a node with just this one sampled path *)
       Tree.node ~label ~children:[ sampled_child ])

let softmin_distribution ~beta (distances : float list) : float list =
  let neg_scaled = List.map distances ~f:(fun d -> Float.neg beta *. d) in
  let max_val = List.fold neg_scaled ~init:Float.neg_infinity ~f:Float.max in
  let exps = List.map neg_scaled ~f:(fun x -> Float.exp (x -. max_val)) in
  let total = List.fold exps ~init:0.0 ~f:( +. ) in
  match Float.( > ) total 0.0 with
  | true -> List.map exps ~f:(fun e -> e /. total)
  | false ->
    let n = List.length distances in
    List.init n ~f:(fun _ -> 1.0 /. Float.of_int n)

let shannon_entropy (probs : float list) : float =
  List.fold probs ~init:0.0 ~f:(fun acc p ->
    match Float.( > ) p 1e-12 with
    | true -> acc -. p *. Float.log p
    | false -> acc)

let locate ~config graph ~game_state_tree =
  let num_clusters = List.length graph.Ev_graph.clusters in
  match num_clusters with
  | 0 -> { weights = []; map_cluster = 0; map_probability = 0.0; entropy = 0.0 }
  | _ ->
    (* Generate samples *)
    let samples = List.init config.num_samples ~f:(fun _ ->
      sample_subtree ~depth:config.sample_depth game_state_tree)
    in
    (* For each cluster, compute average distance to all samples *)
    let avg_distances = List.mapi graph.clusters ~f:(fun _i cluster ->
      let total_dist = List.fold samples ~init:0.0 ~f:(fun acc sample ->
        acc +. Distance.compute_with_config
          ~config:config.distance_config sample cluster.representative)
      in
      total_dist /. Float.of_int config.num_samples)
    in
    (* Softmin to get belief distribution *)
    let probs = softmin_distribution ~beta:config.beta avg_distances in
    let weights = List.mapi probs ~f:(fun i p -> (i, p)) in
    (* Find MAP *)
    let map_cluster, map_probability =
      List.fold weights ~init:(0, 0.0) ~f:(fun (best_i, best_p) (i, p) ->
        match Float.( > ) p best_p with
        | true -> (i, p)
        | false -> (best_i, best_p))
    in
    let entropy = shannon_entropy probs in
    { weights; map_cluster; map_probability; entropy }
