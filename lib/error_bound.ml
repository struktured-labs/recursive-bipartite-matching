let max_leaf_error ?(distance_config = Distance.default_config) t1 t2 merged =
  let _ = distance_config in
  let ev1 = Tree.ev t1 in
  let ev2 = Tree.ev t2 in
  let ev_m = Tree.ev merged in
  Float.max (Float.abs (ev1 -. ev_m)) (Float.abs (ev2 -. ev_m))

let graph_error_analysis graph =
  let errors = List.mapi graph.Ev_graph.clusters ~f:(fun i cluster ->
    let rep_ev = Tree.ev cluster.representative in
    let max_err = List.fold cluster.members ~init:0.0 ~f:(fun acc (_, t) ->
      Float.max acc (Float.abs (Tree.ev t -. rep_ev)))
    in
    (i, max_err))
  in
  let max_error = List.fold errors ~init:0.0 ~f:(fun acc (_, e) -> Float.max acc e) in
  let avg_error =
    let total = List.sum (module Float) errors ~f:snd in
    total /. Float.of_int (Int.max 1 (List.length errors))
  in
  (max_error, avg_error, errors)

let verify_bounds ?(distance_config = Distance.default_config) graph =
  List.mapi graph.Ev_graph.clusters ~f:(fun i cluster ->
    let rep_ev = Tree.ev cluster.representative in
    (* EV error: max |EV(member) - EV(representative)| *)
    let ev_error = List.fold cluster.members ~init:0.0 ~f:(fun acc (_, t) ->
      Float.max acc (Float.abs (Tree.ev t -. rep_ev)))
    in
    (* Distance bound: max distance from any member to representative *)
    let max_dist = List.fold cluster.members ~init:0.0 ~f:(fun acc (_, t) ->
      Float.max acc (Distance.compute_with_config ~config:distance_config
        t cluster.representative))
    in
    (* The bound: EV error should be <= max_dist
       (for equal-weight merges, it should be <= diameter/2,
        but the general bound is <= distance to representative) *)
    let passed = Float.( <= ) ev_error (max_dist +. 0.001) in
    (i, ev_error, max_dist, passed))

let report ?(distance_config = Distance.default_config) graph =
  let bounds = verify_bounds ~distance_config graph in
  let max_error, avg_error, _ = graph_error_analysis graph in
  let all_pass = List.for_all bounds ~f:(fun (_, _, _, p) -> p) in
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (sprintf "=== Error Bound Verification ===\n\
              Max EV error: %.4f  Avg EV error: %.4f\n\
              All bounds hold: %s\n\n"
       max_error avg_error
       (match all_pass with true -> "YES" | false -> "NO"));
  List.iter bounds ~f:(fun (i, ev_err, dist_bound, passed) ->
    let cluster = List.nth_exn graph.clusters i in
    Buffer.add_string buf
      (sprintf "  Cluster %d (%d members): ev_err=%.4f  dist_bound=%.4f  %s\n"
         i (List.length cluster.members) ev_err dist_bound
         (match passed with true -> "PASS" | false -> "FAIL")));
  Buffer.contents buf
