(** Merge multiple distributed MCCFR strategy files.

    Each worker trains independently and saves a cfr_state (regret_sum +
    strategy_sum) pair per player via Marshal.  This tool loads N such
    files, averages the regret_sum and strategy_sum float arrays across
    all workers, and saves the merged result.

    This is the key primitive for distributed CFR: because regret and
    strategy sums are additive, averaging N independent runs with the
    same number of iterations produces an unbiased estimator equivalent
    to a single run of N * iterations.

    Usage:
      opam exec -- dune exec -- rbm-merge-strategies \
        -o merged.dat worker1.dat worker2.dat ... workerN.dat *)

open Rbm

type cfr_pair = Cfr_nolimit.cfr_state * Cfr_nolimit.cfr_state

let load_cfr_state (filename : string) : cfr_pair =
  let ic = In_channel.create filename in
  let (s : cfr_pair) = Marshal.from_channel ic in
  In_channel.close ic;
  s

let save_cfr_state (filename : string) (s : cfr_pair) =
  let oc = Out_channel.create filename in
  Marshal.to_channel oc s [ Marshal.Closures ];
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
  (* Collect all keys *)
  List.iter tables ~f:(fun tbl ->
    Hashtbl.iteri tbl ~f:(fun ~key ~data ->
      match Hashtbl.find result key with
      | None ->
        (* First occurrence -- copy the array *)
        Hashtbl.set result ~key ~data:(Array.copy data)
      | Some existing ->
        (* Accumulate element-wise *)
        let len = Int.min (Array.length existing) (Array.length data) in
        for i = 0 to len - 1 do
          existing.(i) <- existing.(i) +. data.(i)
        done));
  (* Divide by number of sources to get the average *)
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
    let (p0, p1) = load_cfr_state (List.hd_exn input_files) in
    save_cfr_state !output_file (p0, p1);
    printf "Copied %s -> %s\n%!" (List.hd_exn input_files) !output_file
  | n ->
    printf "Merging %d strategy files...\n%!" n;
    let states = List.map input_files ~f:(fun f ->
      printf "  Loading %s...\n%!" f;
      load_cfr_state f)
    in
    let p0_regrets = List.map states ~f:(fun (p0, _) -> p0.regret_sum) in
    let p0_strats  = List.map states ~f:(fun (p0, _) -> p0.strategy_sum) in
    let p1_regrets = List.map states ~f:(fun (_, p1) -> p1.regret_sum) in
    let p1_strats  = List.map states ~f:(fun (_, p1) -> p1.strategy_sum) in
    let merged_p0 : Cfr_nolimit.cfr_state =
      { regret_sum = merge_tables p0_regrets
      ; strategy_sum = merge_tables p0_strats
      }
    in
    let merged_p1 : Cfr_nolimit.cfr_state =
      { regret_sum = merge_tables p1_regrets
      ; strategy_sum = merge_tables p1_strats
      }
    in
    save_cfr_state !output_file (merged_p0, merged_p1);
    let p0_keys = Hashtbl.length merged_p0.regret_sum in
    let p1_keys = Hashtbl.length merged_p1.regret_sum in
    let file_size =
      Int64.to_int_exn (Core_unix.stat !output_file).st_size
    in
    printf "Merged result: P0=%d P1=%d info sets, %d bytes\n%!"
      p0_keys p1_keys file_size;
    printf "Saved to %s\n%!" !output_file
