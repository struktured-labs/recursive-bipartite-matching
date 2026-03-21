(** CFR+ style regret pruning.

    Standalone module — does not modify {!Compact_cfr}.  See .mli for
    full documentation. *)

let should_prune_regrets (regrets : float array) : bool =
  let len = Array.length regrets in
  match Int.equal len 0 with
  | true -> false
  | false -> Array.for_all regrets ~f:(fun r -> Float.( < ) r 0.0)

let prune_state (state : Compact_cfr.cfr_state) ~(pruned : int ref) : unit =
  let keys_to_remove =
    Hashtbl.fold state.entries ~init:[] ~f:(fun ~key ~data acc ->
      match should_prune_regrets (Compact_cfr.entry_regrets_sub data) with
      | true -> key :: acc
      | false -> acc)
  in
  List.iter keys_to_remove ~f:(fun key ->
    Hashtbl.remove state.entries key;
    Int.incr pruned)

let prune_periodically ~(every : int) ~(iter : int) (state : Compact_cfr.cfr_state)
  : unit
  =
  match Int.equal (iter % every) 0 with
  | true ->
    let pruned = ref 0 in
    prune_state state ~pruned;
    (match Int.( > ) !pruned 0 with
     | true ->
       Core.printf "CFR pruning (iter %d): removed %d dominated info sets\n" iter !pruned
     | false -> ())
  | false -> ()

let%test "all_negative_is_prunable" =
  should_prune_regrets [| -1.0; -2.0; -0.5 |]

let%test "one_positive_not_prunable" =
  not (should_prune_regrets [| -1.0; 2.0; -0.5 |])

let%test "all_zeros_not_prunable" =
  not (should_prune_regrets [| 0.0; 0.0; 0.0 |])

let%test "empty_not_prunable" =
  not (should_prune_regrets [||])

let%test "single_negative_prunable" =
  should_prune_regrets [| -0.001 |]

let%test "single_zero_not_prunable" =
  not (should_prune_regrets [| 0.0 |])

let%test "prune_state_removes_dominated" =
  let state = Compact_cfr.create ~size:16 () in
  Hashtbl.set state.entries ~key:1L
    ~data:{ Compact_cfr.data = [| -1.0; -2.0; 0.5; 0.5 |]; n_actions = 2 };
  Hashtbl.set state.entries ~key:2L
    ~data:{ Compact_cfr.data = [| 1.0; -2.0; 0.7; 0.3 |]; n_actions = 2 };
  Hashtbl.set state.entries ~key:3L
    ~data:{ Compact_cfr.data = [| -3.0; -0.1; 0.4; 0.6 |]; n_actions = 2 };
  let pruned = ref 0 in
  prune_state state ~pruned;
  Int.equal !pruned 2
  && Int.equal (Hashtbl.length state.entries) 1
  && Hashtbl.mem state.entries 2L
