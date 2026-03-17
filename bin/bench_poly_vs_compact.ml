(** Quick benchmark comparing Hashtbl.Poly (Cfr_nolimit) vs monomorphic
    (Compact_cfr) memory usage for the same training workload.

    Usage:
      /usr/bin/time -v opam exec -- dune exec -- rbm-bench-poly-vs-compact \
        --mode poly --iterations 100000 --buckets 20
      /usr/bin/time -v opam exec -- dune exec -- rbm-bench-poly-vs-compact \
        --mode compact --iterations 100000 --buckets 20

    Compare "Maximum resident set size" from /usr/bin/time output. *)

open Rbm

let () =
  let mode = ref "compact" in
  let iterations = ref 100_000 in
  let n_buckets = ref 20 in

  let args = [
    ("--mode", Arg.Set_string mode, "MODE  'poly' or 'compact' (default: compact)");
    ("--iterations", Arg.Set_int iterations, "N  iterations (default: 100000)");
    ("--buckets", Arg.Set_int n_buckets, "N  buckets (default: 20)");
  ] in
  Arg.parse args (fun _ -> ()) "bench_poly_vs_compact --mode MODE --iterations N --buckets N";

  let config : Nolimit_holdem.config =
    { deck = Card.full_deck
    ; small_blind = 50
    ; big_blind = 100
    ; starting_stack = 20_000
    ; bet_fractions = [ 0.5; 1.0; 2.0 ]
    ; max_raises_per_round = 4
    ; num_players = 2
    }
  in

  printf "=== Benchmark: %s mode, %d iters, %d buckets ===\n%!" !mode !iterations !n_buckets;

  let abstraction = Abstraction.abstract_preflop_equity ~n_buckets:!n_buckets in

  match String.equal !mode "poly" with
  | true ->
    let (_p0, _p1) =
      Cfr_nolimit.train_mccfr ~config ~abstraction ~iterations:!iterations
        ~report_every:50_000 ()
    in
    printf "Done (poly mode).\n%!"
  | false ->
    let (_p0, _p1) =
      Compact_cfr.train_mccfr ~config ~abstraction ~iterations:!iterations
        ~report_every:50_000 ~initial_size:1_000_000 ()
    in
    printf "Done (compact mode).\n%!"
