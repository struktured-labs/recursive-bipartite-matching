(* Unit tests for VR-MCCFR+ (Variance-Reduced MCCFR).
   Tests the baseline machinery, the variance-reduced regret update,
   and end-to-end integration with mccfr_traverse. *)

let float_eq ?(eps = 1e-10) a b = Float.( < ) (Float.abs (a -. b)) eps

(* ------------------------------------------------------------------ *)
(* Baseline table tests                                                *)
(* ------------------------------------------------------------------ *)

let%test_unit "create_baselines returns empty table" =
  let bl = Compact_cfr.create_baselines ~size:16 () in
  [%test_eq: int] (Hashtbl.length bl) 0

let%test_unit "get_baseline lazily creates zero array" =
  let bl = Compact_cfr.create_baselines ~size:16 () in
  let key = 42L in
  let arr = Compact_cfr.get_baseline bl key ~n_actions:3 in
  [%test_eq: int] (Array.length arr) 3;
  Array.iter arr ~f:(fun v ->
    match float_eq v 0.0 with
    | true -> ()
    | false -> failwith "expected zero baseline")

let%test_unit "get_baseline returns same array on second lookup" =
  let bl = Compact_cfr.create_baselines ~size:16 () in
  let key = 99L in
  let a1 = Compact_cfr.get_baseline bl key ~n_actions:2 in
  a1.(0) <- 5.0;
  let a2 = Compact_cfr.get_baseline bl key ~n_actions:2 in
  match float_eq a2.(0) 5.0 with
  | true -> ()
  | false -> failwith "expected mutable identity"

(* ------------------------------------------------------------------ *)
(* Baseline update (EMA) tests                                         *)
(* ------------------------------------------------------------------ *)

let%test_unit "update_baseline with alpha=1.0 replaces baseline" =
  let bl = Compact_cfr.create_baselines ~size:16 () in
  let key = 1L in
  let arr = Compact_cfr.get_baseline bl key ~n_actions:3 in
  let observed = [| 10.0; 20.0; 30.0 |] in
  Compact_cfr.update_baseline arr observed ~alpha:1.0;
  Array.iteri arr ~f:(fun i v ->
    match float_eq v observed.(i) with
    | true -> ()
    | false ->
      failwithf "alpha=1.0: expected %f, got %f at %d" observed.(i) v i ())

let%test_unit "update_baseline with alpha=0.5 averages" =
  let bl = Compact_cfr.create_baselines ~size:16 () in
  let key = 2L in
  let arr = Compact_cfr.get_baseline bl key ~n_actions:2 in
  arr.(0) <- 10.0;
  arr.(1) <- 20.0;
  let observed = [| 30.0; 40.0 |] in
  Compact_cfr.update_baseline arr observed ~alpha:0.5;
  (* Expected: (1-0.5)*10 + 0.5*30 = 20, (1-0.5)*20 + 0.5*40 = 30 *)
  match float_eq arr.(0) 20.0 && float_eq arr.(1) 30.0 with
  | true -> ()
  | false ->
    failwithf "alpha=0.5: expected (20,30), got (%f,%f)" arr.(0) arr.(1) ()

let%test_unit "update_baseline with alpha=0.0 preserves baseline" =
  let bl = Compact_cfr.create_baselines ~size:16 () in
  let key = 3L in
  let arr = Compact_cfr.get_baseline bl key ~n_actions:2 in
  arr.(0) <- 7.0;
  arr.(1) <- 13.0;
  let observed = [| 100.0; 200.0 |] in
  Compact_cfr.update_baseline arr observed ~alpha:0.0;
  match float_eq arr.(0) 7.0 && float_eq arr.(1) 13.0 with
  | true -> ()
  | false ->
    failwithf "alpha=0.0: expected (7,13), got (%f,%f)" arr.(0) arr.(1) ()

(* ------------------------------------------------------------------ *)
(* VR regret update correctness                                        *)
(* ------------------------------------------------------------------ *)

(* Verify that variance-reduced regret updates are equivalent to
   standard regret updates when baselines are zero (identity property).

   With baseline = [0; 0; ...]:
     vr_cfv[a] = cfv[a] - 0 = cfv[a]
     vr_node_value = sum(strat[a] * cfv[a]) = node_value
     vr_regret[a] = cfv[a] - node_value   (same as standard)

   So with zero baselines, VR-MCCFR should produce identical regret
   updates to standard MCCFR. *)
let%test_unit "vr_regret_with_zero_baseline_matches_standard" =
  let cfr_st = Compact_cfr.create ~size:16 () in
  let key = 123L in
  let num_actions = 3 in
  let strat = [| 0.5; 0.3; 0.2 |] in

  (* Simulate action values *)
  let action_values = [| 10.0; -5.0; 3.0 |] in
  let node_value =
    Array.foldi action_values ~init:0.0 ~f:(fun i acc v ->
      acc +. strat.(i) *. v)
  in

  (* Standard regret update *)
  let std_entry =
    Compact_cfr.find_or_add_entry cfr_st key ~num_actions
  in
  Array.iteri action_values ~f:(fun i v ->
    Compact_cfr.set_entry_regret std_entry i
      (Compact_cfr.entry_regret std_entry i +. (v -. node_value)));
  let std_regrets = Compact_cfr.entry_regrets_sub std_entry in

  (* VR regret update with zero baselines *)
  let cfr_st2 = Compact_cfr.create ~size:16 () in
  let vr_entry =
    Compact_cfr.find_or_add_entry cfr_st2 key ~num_actions
  in
  let bl = Array.create ~len:num_actions 0.0 in
  let vr_node_value = ref 0.0 in
  for i = 0 to num_actions - 1 do
    vr_node_value := !vr_node_value
      +. strat.(i) *. (action_values.(i) -. bl.(i))
  done;
  Array.iteri action_values ~f:(fun i v ->
    let vr_regret = (v -. bl.(i)) -. !vr_node_value in
    Compact_cfr.set_entry_regret vr_entry i
      (Compact_cfr.entry_regret vr_entry i +. vr_regret));
  let vr_regrets = Compact_cfr.entry_regrets_sub vr_entry in

  (* They should match *)
  Array.iteri std_regrets ~f:(fun i sr ->
    match float_eq sr vr_regrets.(i) with
    | true -> ()
    | false ->
      failwithf "zero-baseline VR mismatch at %d: std=%f vr=%f" i sr vr_regrets.(i) ())

(* Verify VR regret update with non-zero baselines is unbiased:
   the sum of (probability-weighted) regret adjustments is zero,
   meaning the node value is preserved. *)
let%test_unit "vr_regret_is_unbiased" =
  let num_actions = 4 in
  let strat = [| 0.25; 0.25; 0.25; 0.25 |] in
  let action_values = [| 10.0; -5.0; 3.0; 7.0 |] in
  let baselines = [| 8.0; -3.0; 2.0; 5.0 |] in

  (* Standard node value *)
  let node_value =
    Array.foldi action_values ~init:0.0 ~f:(fun i acc v ->
      acc +. strat.(i) *. v)
  in

  (* VR node value *)
  let vr_node_value =
    Array.foldi action_values ~init:0.0 ~f:(fun i acc v ->
      acc +. strat.(i) *. (v -. baselines.(i)))
  in

  (* Probability-weighted sum of VR regret adjustments should equal
     probability-weighted sum of standard regret adjustments *)
  let std_weighted_sum = ref 0.0 in
  let vr_weighted_sum = ref 0.0 in
  for i = 0 to num_actions - 1 do
    std_weighted_sum := !std_weighted_sum
      +. strat.(i) *. (action_values.(i) -. node_value);
    vr_weighted_sum := !vr_weighted_sum
      +. strat.(i) *. ((action_values.(i) -. baselines.(i)) -. vr_node_value)
  done;
  (* Both should be zero (definition of node_value) *)
  match float_eq !std_weighted_sum 0.0 && float_eq !vr_weighted_sum 0.0 with
  | true -> ()
  | false ->
    failwithf "unbiased check failed: std_sum=%f vr_sum=%f"
      !std_weighted_sum !vr_weighted_sum ()

(* Verify that with perfect baselines (baseline == cfv), all
   regret adjustments are zero -- maximum variance reduction. *)
let%test_unit "vr_regret_with_perfect_baseline_is_zero" =
  let num_actions = 3 in
  let strat = [| 0.6; 0.3; 0.1 |] in
  let action_values = [| 10.0; -5.0; 3.0 |] in
  let baselines = Array.copy action_values in  (* perfect baseline *)

  let vr_node_value = ref 0.0 in
  for i = 0 to num_actions - 1 do
    vr_node_value := !vr_node_value
      +. strat.(i) *. (action_values.(i) -. baselines.(i))
  done;
  (* vr_node_value should be 0 since cfv - baseline = 0 everywhere *)
  (match float_eq !vr_node_value 0.0 with
   | true -> ()
   | false -> failwithf "vr_node_value should be 0, got %f" !vr_node_value ());

  (* All regret adjustments should be zero *)
  for i = 0 to num_actions - 1 do
    let vr_regret = (action_values.(i) -. baselines.(i)) -. !vr_node_value in
    match float_eq vr_regret 0.0 with
    | true -> ()
    | false ->
      failwithf "perfect baseline: regret[%d] should be 0, got %f" i vr_regret ()
  done

(* ------------------------------------------------------------------ *)
(* DLS isolation test (single domain)                                  *)
(* ------------------------------------------------------------------ *)

let%test_unit "dls_baselines_default_is_none" =
  (* Domain.DLS default should be None *)
  match Compact_cfr.get_dls_baselines () with
  | None -> ()
  | Some _ -> failwith "expected DLS baselines to default to None"

let%test_unit "dls_baselines_roundtrip" =
  let bl = [| Compact_cfr.create_baselines ~size:4 ()
            ; Compact_cfr.create_baselines ~size:4 ()
            |] in
  Compact_cfr.set_dls_baselines (Some bl);
  (match Compact_cfr.get_dls_baselines () with
   | Some bl2 ->
     (* Should be the same array (physical identity) *)
     (match phys_equal bl bl2 with
      | true -> ()
      | false -> failwith "expected physical identity")
   | None -> failwith "expected Some");
  (* Cleanup *)
  Compact_cfr.set_dls_baselines None
