(** Merge multiple distributed MCCFR strategy files.

    Each worker trains independently and saves a cfr_state (regret_sum +
    strategy_sum) pair per player.  This tool loads N such files, averages
    the regret_sum and strategy_sum float arrays across all workers, and
    saves the merged result.

    This is the key primitive for distributed CFR: because regret and
    strategy sums are additive, averaging N independent runs with the
    same number of iterations produces an unbiased estimator equivalent
    to a single run of N * iterations.

    Serialization format: Marshal of
      (string * float array) list *   -- P0 regret_sum
      (string * float array) list *   -- P0 strategy_sum
      (string * float array) list *   -- P1 regret_sum
      (string * float array) list     -- P1 strategy_sum

    We use association lists instead of Hashtbl.Poly.t to avoid Marshal
    closure compatibility issues across different executables.

    Usage:
      opam exec -- dune exec -- rbm-merge-strategies \
        -o merged.dat worker1.dat worker2.dat ... workerN.dat *)

(** Serialized form: four association lists (no closures). *)
type serialized_state =
  (string * float array) list
  * (string * float array) list
  * (string * float array) list
  * (string * float array) list

let hashtbl_to_alist (tbl : (string, float array) Hashtbl.Poly.t)
  : (string * float array) list =
  Hashtbl.fold tbl ~init:[] ~f:(fun ~key ~data acc -> (key, data) :: acc)

let alist_to_hashtbl (alist : (string * float array) list)
  : (string, float array) Hashtbl.Poly.t =
  let tbl = Hashtbl.Poly.create ~size:(List.length alist) () in
  List.iter alist ~f:(fun (key, data) -> Hashtbl.set tbl ~key ~data);
  tbl

let load_file (filename : string)
  : (string, float array) Hashtbl.Poly.t
    * (string, float array) Hashtbl.Poly.t
    * (string, float array) Hashtbl.Poly.t
    * (string, float array) Hashtbl.Poly.t =
  let ic = In_channel.create filename in
  let (p0_reg, p0_strat, p1_reg, p1_strat : serialized_state) =
    Marshal.from_channel ic
  in
  In_channel.close ic;
  ( alist_to_hashtbl p0_reg
  , alist_to_hashtbl p0_strat
  , alist_to_hashtbl p1_reg
  , alist_to_hashtbl p1_strat )

let save_file (filename : string)
    (p0_reg : (string, float array) Hashtbl.Poly.t)
    (p0_strat : (string, float array) Hashtbl.Poly.t)
    (p1_reg : (string, float array) Hashtbl.Poly.t)
    (p1_strat : (string, float array) Hashtbl.Poly.t) =
  let data : serialized_state =
    ( hashtbl_to_alist p0_reg
    , hashtbl_to_alist p0_strat
    , hashtbl_to_alist p1_reg
    , hashtbl_to_alist p1_strat )
  in
  let oc = Out_channel.create filename in
  Marshal.to_channel oc data [];
  Out_channel.close oc

(** Merge a single hashtable from multiple sources by summing (then
    dividing by count).  For each key present in any source, the float
    arrays are element-wise averaged.  Missing keys in a source
    contribute zeros. *)
let merge_tables
    (tables : (string, float array) Hashtbl.Poly.t list)
  : (string, float array) Hashtbl.Poly.t =
  let n = Float.of_int (List.length tables) in
  let result = Hashtbl.Poly.create () in
  List.iter tables ~f:(fun tbl ->
    Hashtbl.iteri tbl ~f:(fun ~key ~data ->
      match Hashtbl.find result key with
      | None ->
        Hashtbl.set result ~key ~data:(Array.copy data)
      | Some existing ->
        let len = Int.min (Array.length existing) (Array.length data) in
        for i = 0 to len - 1 do
          existing.(i) <- existing.(i) +. data.(i)
        done));
  Hashtbl.iteri result ~f:(fun ~key:_ ~data ->
    Array.iteri data ~f:(fun i v ->
      data.(i) <- v /. n));
  result

let () =
  let output_file = ref "merged_strategy.dat" in
  let input_files = ref [] in
  let args = [
    ("-o", Arg.Set_string output_file,
     "FILE  Output merged strategy file (default: merged_strategy.dat)");
  ] in
  Arg.parse args
    (fun file -> input_files := file :: !input_files)
    "rbm-merge-strategies [-o OUTPUT] FILE1 FILE2 ... FILEN";
  let input_files = List.rev !input_files in
  match List.length input_files with
  | 0 ->
    eprintf "Error: no input strategy files specified.\n%!";
    eprintf "Usage: rbm-merge-strategies [-o OUTPUT] FILE1 FILE2 ... FILEN\n%!";
    Core.exit 1
  | 1 ->
    eprintf "Warning: only one input file; copying to output.\n%!";
    let (p0r, p0s, p1r, p1s) = load_file (List.hd_exn input_files) in
    save_file !output_file p0r p0s p1r p1s;
    printf "Copied %s -> %s\n%!" (List.hd_exn input_files) !output_file
  | n ->
    printf "Merging %d strategy files...\n%!" n;
    let loaded = List.map input_files ~f:(fun f ->
      printf "  Loading %s...\n%!" f;
      load_file f)
    in
    let p0_regrets = List.map loaded ~f:(fun (r, _, _, _) -> r) in
    let p0_strats  = List.map loaded ~f:(fun (_, s, _, _) -> s) in
    let p1_regrets = List.map loaded ~f:(fun (_, _, r, _) -> r) in
    let p1_strats  = List.map loaded ~f:(fun (_, _, _, s) -> s) in
    let merged_p0r = merge_tables p0_regrets in
    let merged_p0s = merge_tables p0_strats in
    let merged_p1r = merge_tables p1_regrets in
    let merged_p1s = merge_tables p1_strats in
    save_file !output_file merged_p0r merged_p0s merged_p1r merged_p1s;
    let p0_keys = Hashtbl.length merged_p0r in
    let p1_keys = Hashtbl.length merged_p1r in
    let file_size =
      Int64.to_int_exn (Core_unix.stat !output_file).st_size
    in
    printf "Merged result: P0=%d P1=%d info sets, %d bytes\n%!"
      p0_keys p1_keys file_size;
    printf "Saved to %s\n%!" !output_file
