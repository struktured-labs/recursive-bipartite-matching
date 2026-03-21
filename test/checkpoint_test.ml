(** Round-trip tests for chunked checkpoint serialization. *)

let float_eq ?(eps = 1e-15) a b = Float.( < ) (Float.abs (a -. b)) eps

let make_test_states () : Compact_cfr.cfr_state array =
  let p0 = Compact_cfr.create ~size:16 () in
  let p1 = Compact_cfr.create ~size:16 () in
  (* P0 entries *)
  Hashtbl.set p0.entries ~key:100L
    ~data:{ Compact_cfr.regrets = [| 1.5; -2.3; 0.0 |]
          ; strategy = [| 10.0; 20.0; 30.0 |] };
  Hashtbl.set p0.entries ~key:201L
    ~data:{ Compact_cfr.regrets = [| 100.0; 200.0 |]
          ; strategy = [| 50.0; 50.0 |] };
  Hashtbl.set p0.entries ~key:302L
    ~data:{ Compact_cfr.regrets = [| 0.001; 99999.9; -1e10 |]
          ; strategy = [| 0.0; 0.0; 0.0 |] };
  (* P1 entries *)
  Hashtbl.set p1.entries ~key:700L
    ~data:{ Compact_cfr.regrets = [| 42.0 |]
          ; strategy = [| 42.0 |] };
  Hashtbl.set p1.entries ~key:809L
    ~data:{ Compact_cfr.regrets = [| 0.0; 0.0; 0.0; 0.0 |]
          ; strategy = [| 1.0; 2.0; 3.0; 4.0 |] };
  [| p0; p1 |]

let assert_entry_equal
    (expected : Compact_cfr.cfr_entry)
    (actual : Compact_cfr.cfr_entry)
    ~(label : string) ~(key : int64) =
  [%test_eq: int] (Array.length expected.regrets) (Array.length actual.regrets);
  Array.iteri expected.regrets ~f:(fun i e ->
    match float_eq e actual.regrets.(i) with
    | true -> ()
    | false ->
      failwithf "%s: key %Ld regrets[%d]: expected %f got %f"
        label key i e actual.regrets.(i) ());
  [%test_eq: int] (Array.length expected.strategy) (Array.length actual.strategy);
  Array.iteri expected.strategy ~f:(fun i e ->
    match float_eq e actual.strategy.(i) with
    | true -> ()
    | false ->
      failwithf "%s: key %Ld strategy[%d]: expected %f got %f"
        label key i e actual.strategy.(i) ())

let assert_entries_equal
    (expected : (Int64.t, Compact_cfr.cfr_entry) Hashtbl.t)
    (actual : (Int64.t, Compact_cfr.cfr_entry) Hashtbl.t)
    ~(label : string) =
  [%test_eq: int] (Hashtbl.length expected) (Hashtbl.length actual);
  Hashtbl.iteri expected ~f:(fun ~key ~data:exp_entry ->
    match Hashtbl.find actual key with
    | None -> failwithf "%s: missing key %Ld" label key ()
    | Some act_entry ->
      assert_entry_equal exp_entry act_entry ~label ~key)

let assert_states_equal
    (expected : Compact_cfr.cfr_state array)
    (actual : Compact_cfr.cfr_state array) =
  assert_entries_equal expected.(0).entries actual.(0).entries ~label:"P0";
  assert_entries_equal expected.(1).entries actual.(1).entries ~label:"P1"

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
  let loaded = Compact_cfr.load_checkpoint ~filename in
  assert_states_equal states loaded;
  Core_unix.unlink filename

let%test_unit "autodetect_marshal" =
  let states = make_test_states () in
  let filename = "test_autodetect_marshal.dat" in
  Compact_cfr.save_checkpoint_marshal ~filename states;
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
  let states = make_test_states () in
  let filename = "test_cross_format.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename states;
  let loaded = Compact_cfr.load_checkpoint_chunked ~filename in
  let filename2 = "test_cross_format2.dat" in
  Compact_cfr.save_checkpoint_marshal ~filename:filename2 loaded;
  let reloaded = Compact_cfr.load_checkpoint_marshal ~filename:filename2 in
  assert_states_equal states reloaded;
  Core_unix.unlink filename;
  Core_unix.unlink filename2

let%test_unit "large_checkpoint_roundtrip" =
  let p0 = Compact_cfr.create ~size:100_000 () in
  let p1 = Compact_cfr.create ~size:100_000 () in
  for i = 0 to 99_999 do
    let key = Int64.of_int (i * 1_000_003 + 42) in
    let n_actions = 3 + (i mod 5) in
    let regrets = Array.init n_actions ~f:(fun j ->
      Float.of_int (i * 7 + j) *. 0.001 -. 50.0) in
    let strats = Array.init n_actions ~f:(fun j ->
      Float.of_int (i * 3 + j + 1) *. 0.01) in
    Hashtbl.set p0.entries ~key
      ~data:{ Compact_cfr.regrets; strategy = strats };
    Hashtbl.set p1.entries ~key
      ~data:{ Compact_cfr.regrets = Array.map regrets ~f:Float.neg
            ; strategy = strats }
  done;
  let states = [| p0; p1 |] in
  let filename = "test_large_roundtrip.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename states;
  let loaded = Compact_cfr.load_checkpoint_chunked ~filename in
  assert_states_equal states loaded;
  let filename2 = "test_large_roundtrip2.dat" in
  Compact_cfr.save_checkpoint_chunked ~filename:filename2 loaded;
  let reloaded = Compact_cfr.load_checkpoint_chunked ~filename:filename2 in
  assert_states_equal states reloaded;
  Core_unix.unlink filename;
  Core_unix.unlink filename2

let%test_unit "make_info_key_deterministic" =
  let buckets = [| 34; 29; 78; 3 |] in
  let k1 = Compact_cfr.make_info_key ~buckets ~round_idx:3 ~history:"cc/kk/kh" in
  let k2 = Compact_cfr.make_info_key ~buckets ~round_idx:3 ~history:"cc/kk/kh" in
  [%test_eq: int64] k1 k2

let%test_unit "make_info_key_different_inputs" =
  let buckets1 = [| 34; 29; 78; 3 |] in
  let buckets2 = [| 34; 29; 78; 4 |] in
  let k1 = Compact_cfr.make_info_key ~buckets:buckets1 ~round_idx:3 ~history:"cc/kk/kh" in
  let k2 = Compact_cfr.make_info_key ~buckets:buckets2 ~round_idx:3 ~history:"cc/kk/kh" in
  let k3 = Compact_cfr.make_info_key ~buckets:buckets1 ~round_idx:2 ~history:"cc/kk/kh" in
  let k4 = Compact_cfr.make_info_key ~buckets:buckets1 ~round_idx:3 ~history:"cc/kk/kc" in
  [%test_eq: bool] (Int64.equal k1 k2) false;
  [%test_eq: bool] (Int64.equal k1 k3) false;
  [%test_eq: bool] (Int64.equal k1 k4) false
