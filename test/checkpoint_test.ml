(** Round-trip tests for chunked checkpoint serialization. *)

let float_eq ?(eps = 1e-15) a b = Float.( < ) (Float.abs (a -. b)) eps

let make_test_states () : Compact_cfr.cfr_state array =
  let p0 = Compact_cfr.create ~size:16 () in
  let p1 = Compact_cfr.create ~size:16 () in
  (* P0 regret_sum *)
  Hashtbl.set p0.regret_sum ~key:"B0|" ~data:[| 1.5; -2.3; 0.0 |];
  Hashtbl.set p0.regret_sum ~key:"B1:2|kc" ~data:[| 100.0; 200.0 |];
  Hashtbl.set p0.regret_sum ~key:"B3:4:5:6|kk/kc" ~data:[| 0.001; 99999.9; -1e10 |];
  (* P0 strategy_sum *)
  Hashtbl.set p0.strategy_sum ~key:"B0|" ~data:[| 10.0; 20.0; 30.0 |];
  Hashtbl.set p0.strategy_sum ~key:"B1:2|kc" ~data:[| 50.0; 50.0 |];
  (* P1 regret_sum *)
  Hashtbl.set p1.regret_sum ~key:"B7|f" ~data:[| 42.0 |];
  (* P1 strategy_sum *)
  Hashtbl.set p1.strategy_sum ~key:"B7|f" ~data:[| 42.0 |];
  Hashtbl.set p1.strategy_sum ~key:"B8:9|kk/kb0.5c" ~data:[| 1.0; 2.0; 3.0; 4.0 |];
  [| p0; p1 |]

let assert_hashtbl_equal
    (expected : (string, float array) Hashtbl.t)
    (actual : (string, float array) Hashtbl.t)
    ~(label : string) =
  [%test_eq: int] (Hashtbl.length expected) (Hashtbl.length actual);
  Hashtbl.iteri expected ~f:(fun ~key ~data:exp_arr ->
    match Hashtbl.find actual key with
    | None -> failwithf "%s: missing key %S" label key ()
    | Some act_arr ->
      [%test_eq: int] (Array.length exp_arr) (Array.length act_arr);
      Array.iteri exp_arr ~f:(fun i e ->
        match float_eq e act_arr.(i) with
        | true -> ()
        | false ->
          failwithf "%s: key %S index %d: expected %f got %f"
            label key i e act_arr.(i) ()))

let assert_states_equal
    (expected : Compact_cfr.cfr_state array)
    (actual : Compact_cfr.cfr_state array) =
  assert_hashtbl_equal expected.(0).regret_sum actual.(0).regret_sum ~label:"P0.regret_sum";
  assert_hashtbl_equal expected.(0).strategy_sum actual.(0).strategy_sum ~label:"P0.strategy_sum";
  assert_hashtbl_equal expected.(1).regret_sum actual.(1).regret_sum ~label:"P1.regret_sum";
  assert_hashtbl_equal expected.(1).strategy_sum actual.(1).strategy_sum ~label:"P1.strategy_sum"

let%test_unit "chunked_roundtrip" =
  let states = make_test_states () in
  let filename = "test_chunked_roundtrip.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename states;
  let loaded = Compact_cfr.load_checkpoint_chunked ~filename in
  assert_states_equal states loaded;
  Core_unix.unlink filename

let%test_unit "marshal_roundtrip" =
  let states = make_test_states () in
  let filename = "test_marshal_roundtrip.dat" in
  Compact_cfr.save_checkpoint_marshal ~filename states;
  let loaded = Compact_cfr.load_checkpoint_marshal ~filename in
  assert_states_equal states loaded;
  Core_unix.unlink filename

let%test_unit "autodetect_chunked" =
  let states = make_test_states () in
  let filename = "test_autodetect_chunked.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename states;
  (* load_checkpoint should auto-detect chunked format *)
  let loaded = Compact_cfr.load_checkpoint ~filename in
  assert_states_equal states loaded;
  Core_unix.unlink filename

let%test_unit "autodetect_marshal" =
  let states = make_test_states () in
  let filename = "test_autodetect_marshal.dat" in
  Compact_cfr.save_checkpoint_marshal ~filename states;
  (* load_checkpoint should auto-detect marshal format *)
  let loaded = Compact_cfr.load_checkpoint ~filename in
  assert_states_equal states loaded;
  Core_unix.unlink filename

let%test_unit "is_chunked_format_true" =
  let states = make_test_states () in
  let filename = "test_is_chunked.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename states;
  [%test_eq: bool] (Compact_cfr.is_chunked_format ~filename) true;
  Core_unix.unlink filename

let%test_unit "is_chunked_format_false_on_marshal" =
  let states = make_test_states () in
  let filename = "test_is_marshal.dat" in
  Compact_cfr.save_checkpoint_marshal ~filename states;
  [%test_eq: bool] (Compact_cfr.is_chunked_format ~filename) false;
  Core_unix.unlink filename

let%test_unit "empty_state_roundtrip" =
  let states = [| Compact_cfr.create ~size:1 (); Compact_cfr.create ~size:1 () |] in
  let filename = "test_empty_roundtrip.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename states;
  let loaded = Compact_cfr.load_checkpoint_chunked ~filename in
  assert_states_equal states loaded;
  Core_unix.unlink filename

let%test_unit "cross_format_roundtrip" =
  (* Save with marshal, load with chunked should fail detection but
     save with chunked should produce identical reload *)
  let states = make_test_states () in
  let filename = "test_cross_format.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename states;
  let loaded = Compact_cfr.load_checkpoint_chunked ~filename in
  (* Now save the loaded state with marshal and reload *)
  let filename2 = "test_cross_format2.dat" in
  Compact_cfr.save_checkpoint_marshal ~filename:filename2 loaded;
  let reloaded = Compact_cfr.load_checkpoint_marshal ~filename:filename2 in
  assert_states_equal states reloaded;
  Core_unix.unlink filename;
  Core_unix.unlink filename2
