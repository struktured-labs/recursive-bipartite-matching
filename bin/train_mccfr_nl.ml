(** Standalone NL MCCFR trainer that saves raw cfr_state.

    Unlike slumbot_client --train (which saves averaged strategies in
    Sexp format), this trainer saves the raw cfr_state (regret_sum +
    strategy_sum) in Marshal format.  This is required for distributed
    training: workers save raw state, then rbm-merge-strategies averages
    the regret and strategy sums across all workers.

    Uses {!Compact_cfr} (monomorphic string hashtables, pre-sized) for
    ~3x lower memory overhead vs {!Cfr_nolimit} (Hashtbl.Poly).

    Supports periodic checkpointing via [--checkpoint-every N] so that
    intermediate state survives OOM kills during long cloud runs.

    Usage:
      opam exec -- dune exec -- rbm-train-mccfr-nl \
        --iterations 500000 --buckets 20 --output strategy.dat \
        --checkpoint-every 100000 --checkpoint-prefix ckpt *)

open Rbm

let () =
  let iterations = ref 100_000 in
  let n_buckets = ref 20 in
  let output_file = ref "strategy_cfr_state.dat" in
  let report_every = ref 10_000 in
  let initial_size = ref 1_000_000 in
  let checkpoint_every = ref 0 in
  let checkpoint_prefix = ref "checkpoint" in
  let format = ref "chunked" in
  let bucket_method_str = ref "equity" in
  let rbm_epsilon = ref 0.5 in
  let bet_fracs_str = ref "" in

  let args = [
    ("--iterations", Arg.Set_int iterations,
     "N  MCCFR iterations (default: 100000)");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Preflop abstraction buckets (default: 20)");
    ("--output", Arg.Set_string output_file,
     "FILE  Output cfr_state file (default: strategy_cfr_state.dat)");
    ("--report-every", Arg.Set_int report_every,
     "N  Report progress every N iterations (default: 10000)");
    ("--initial-size", Arg.Set_int initial_size,
     "N  Pre-size hash tables to N entries (default: 1000000)");
    ("--checkpoint-every", Arg.Set_int checkpoint_every,
     "N  Save checkpoint every N iterations (default: 0 = off)");
    ("--checkpoint-prefix", Arg.Set_string checkpoint_prefix,
     "PREFIX  Checkpoint filename prefix (default: checkpoint)");
    ("--format", Arg.Set_string format,
     "FORMAT  Checkpoint format: chunked (default, low memory) or marshal (legacy)");
    ("--bucket-method", Arg.Set_string bucket_method_str,
     "METHOD  Bucketing method: equity (default) or rbm");
    ("--rbm-epsilon", Arg.Set_float rbm_epsilon,
     "FLOAT  RBM clustering epsilon (default: 0.5)");
    ("--bet-fractions", Arg.Set_string bet_fracs_str,
     "LIST  Comma-separated bet fractions (default: 0.5,1.0,2.0; expanded: 0.25,0.33,0.5,0.75,1.0,1.5,2.0)");
  ] in
  Arg.parse args (fun _ -> ())
    "rbm-train-mccfr-nl [--iterations N] [--buckets N] [--output FILE] [--checkpoint-every N] [--format chunked|marshal]";

  let base_config : Nolimit_holdem.config =
    { deck = Card.full_deck
    ; small_blind = 50
    ; big_blind = 100
    ; starting_stack = 20_000
    ; bet_fractions = [ 0.5; 1.0; 2.0 ]
    ; max_raises_per_round = 4
    ; num_players = 2
    }
  in
  let config =
    match !bet_fracs_str with
    | "" -> base_config
    | "expanded" ->
      { base_config with
        bet_fractions = [ 0.25; 0.33; 0.5; 0.75; 1.0; 1.5; 2.0 ] }
    | s ->
      let fracs = String.split s ~on:','
        |> List.map ~f:Float.of_string in
      { base_config with bet_fractions = fracs }
  in
  let bucket_method : Compact_cfr.bucket_method =
    match !bucket_method_str with
    | "rbm" ->
      let distance_config = Distance.default_config in
      Rbm_based { epsilon = !rbm_epsilon; distance_config }
    | _ -> Equity_based
  in

  printf "=== NL MCCFR Trainer (compact storage, raw cfr_state output) ===\n%!";
  printf "  Iterations:       %d\n%!" !iterations;
  printf "  Buckets:          %d\n%!" !n_buckets;
  printf "  Output:           %s\n%!" !output_file;
  printf "  Initial size:     %d\n%!" !initial_size;
  printf "  Checkpoint every: %d%s\n%!" !checkpoint_every
    (match !checkpoint_every > 0 with
     | true -> sprintf " (prefix: %s)" !checkpoint_prefix
     | false -> " (disabled)");
  printf "  Format:           %s\n%!" !format;
  printf "  Config:           SB=%d BB=%d stack=%d fracs=[%s]\n%!"
    config.small_blind config.big_blind config.starting_stack
    (String.concat ~sep:";" (List.map config.bet_fractions ~f:Float.to_string));
  (match bucket_method with
   | Compact_cfr.Rbm_based { epsilon; _ } ->
     printf "  Bucketing:        RBM (epsilon=%.3f)\n%!" epsilon
   | Compact_cfr.Equity_based ->
     printf "  Bucketing:        equity\n%!");
  printf "\n%!";

  let save_fn =
    match String.equal !format "marshal" with
    | true  -> Compact_cfr.save_checkpoint_marshal
    | false -> Compact_cfr.save_checkpoint_chunked
  in

  (* Build preflop abstraction *)
  printf "Building %d-bucket preflop abstraction...\n%!" !n_buckets;
  let t0 = Core_unix.gettimeofday () in
  let abstraction = Abstraction.abstract_preflop_equity ~n_buckets:!n_buckets in
  let t1 = Core_unix.gettimeofday () in
  printf "  Abstraction built in %.2fs\n\n%!" (t1 -. t0);

  (* Train -- we replicate the training loop to capture raw cfr_state *)
  let cfr_states =
    [| Compact_cfr.create ~size:!initial_size ()
     ; Compact_cfr.create ~size:!initial_size ()
    |]
  in
  let postflop_states =
    match bucket_method with
    | Compact_cfr.Rbm_based _ ->
      [| Compact_cfr.create_postflop_state ()
       ; Compact_cfr.create_postflop_state ()
      |]
    | Compact_cfr.Equity_based -> [||]
  in
  let util_sum = ref 0.0 in
  let t_train_start = Core_unix.gettimeofday () in

  for iter = 1 to !iterations do
    let (p1_cards, p2_cards, board) = Compact_cfr.sample_deal () in
    let p1_buckets =
      match bucket_method with
      | Compact_cfr.Equity_based ->
        Compact_cfr.precompute_buckets_equity ~abstraction ~hole_cards:p1_cards ~board
      | Compact_cfr.Rbm_based { epsilon; distance_config } ->
        Compact_cfr.precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
          ~postflop:postflop_states.(0) ~hole_cards:p1_cards ~board ~player:0
    in
    let p2_buckets =
      match bucket_method with
      | Compact_cfr.Equity_based ->
        Compact_cfr.precompute_buckets_equity ~abstraction ~hole_cards:p2_cards ~board
      | Compact_cfr.Rbm_based { epsilon; distance_config } ->
        Compact_cfr.precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
          ~postflop:postflop_states.(1) ~hole_cards:p2_cards ~board ~player:1
    in
    let traverser = (iter - 1) % 2 in
    let p_invested = [| config.small_blind; config.big_blind |] in
    let p_stack = [|
      config.starting_stack - config.small_blind;
      config.starting_stack - config.big_blind;
    |] in
    let round_start_invested = [| config.small_blind; config.big_blind |] in
    let state : Compact_cfr.nl_state = {
      to_act = 0;
      round_idx = 0;
      num_raises = 1;
      current_bet = config.big_blind;
      p_invested;
      p_stack;
      round_start_invested;
      actions_remaining = 2;
    } in
    let value = Compact_cfr.mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:"" ~state ~traverser ~cfr_states in
    util_sum := !util_sum +. value;
    (match iter % !report_every = 0 with
     | true ->
       let avg_util = !util_sum /. Float.of_int iter in
       let elapsed = Core_unix.gettimeofday () -. t_train_start in
       let rate = Float.of_int iter /. elapsed in
       let n0 = Hashtbl.length cfr_states.(0).regret_sum in
       let n1 = Hashtbl.length cfr_states.(1).regret_sum in
       printf "  [%d/%d] avg_util=%.4f infosets=(%d,%d) %.0f iter/s\n%!"
         iter !iterations avg_util n0 n1 rate
     | false -> ());
    (match !checkpoint_every > 0 && iter % !checkpoint_every = 0 with
     | true ->
       let filename = sprintf "%s_%d.dat" !checkpoint_prefix iter in
       printf "  [Checkpoint] Saving %s ...\n%!" filename;
       save_fn ~filename cfr_states;
       let file_size = Int64.to_int_exn (Core_unix.stat filename).st_size in
       printf "  [Checkpoint] Done (%.1f MB)\n%!"
         (Float.of_int file_size /. 1_048_576.0)
     | false -> ())
  done;

  let t_train_end = Core_unix.gettimeofday () in
  let train_elapsed = t_train_end -. t_train_start in

  let n0 = Hashtbl.length cfr_states.(0).regret_sum in
  let n1 = Hashtbl.length cfr_states.(1).regret_sum in
  printf "\nTraining complete in %.1fs (%.0f iter/s)\n%!"
    train_elapsed (Float.of_int !iterations /. train_elapsed);
  printf "  P0: %d info sets (%d regret + %d strategy)\n%!" n0
    (Hashtbl.length cfr_states.(0).regret_sum)
    (Hashtbl.length cfr_states.(0).strategy_sum);
  printf "  P1: %d info sets (%d regret + %d strategy)\n%!" n1
    (Hashtbl.length cfr_states.(1).regret_sum)
    (Hashtbl.length cfr_states.(1).strategy_sum);

  (* Save final raw cfr_state *)
  printf "\nSaving raw cfr_state to %s...\n%!" !output_file;
  save_fn ~filename:!output_file cfr_states;
  let file_size = Int64.to_int_exn (Core_unix.stat !output_file).st_size in
  printf "  File size: %d bytes (%.1f MB)\n%!" file_size
    (Float.of_int file_size /. 1_048_576.0);
  printf "\n=== Done ===\n%!"
