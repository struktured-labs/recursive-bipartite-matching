(** Standalone NL MCCFR trainer that saves raw cfr_state.

    Unlike slumbot_client --train (which saves averaged strategies in
    Sexp format), this trainer saves the raw cfr_state (regret_sum +
    strategy_sum) in Marshal format.  This is required for distributed
    training: workers save raw state, then rbm-merge-strategies averages
    the regret and strategy sums across all workers.

    Usage:
      opam exec -- dune exec -- rbm-train-mccfr-nl \
        --iterations 500000 --buckets 20 --output strategy.dat *)

open Rbm

let () =
  let iterations = ref 100_000 in
  let n_buckets = ref 20 in
  let output_file = ref "strategy_cfr_state.dat" in
  let report_every = ref 10_000 in

  let args = [
    ("--iterations", Arg.Set_int iterations,
     "N  MCCFR iterations (default: 100000)");
    ("--buckets", Arg.Set_int n_buckets,
     "N  Preflop abstraction buckets (default: 20)");
    ("--output", Arg.Set_string output_file,
     "FILE  Output cfr_state file in Marshal format (default: strategy_cfr_state.dat)");
    ("--report-every", Arg.Set_int report_every,
     "N  Report progress every N iterations (default: 10000)");
  ] in
  Arg.parse args (fun _ -> ())
    "rbm-train-mccfr-nl [--iterations N] [--buckets N] [--output FILE]";

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

  printf "=== NL MCCFR Trainer (raw cfr_state output) ===\n%!";
  printf "  Iterations:  %d\n%!" !iterations;
  printf "  Buckets:     %d\n%!" !n_buckets;
  printf "  Output:      %s\n%!" !output_file;
  printf "  Config:      SB=%d BB=%d stack=%d fracs=[0.5;1.0;2.0]\n%!"
    config.small_blind config.big_blind config.starting_stack;
  printf "\n%!";

  (* Build preflop abstraction *)
  printf "Building %d-bucket preflop abstraction...\n%!" !n_buckets;
  let t0 = Core_unix.gettimeofday () in
  let abstraction = Abstraction.abstract_preflop_equity ~n_buckets:!n_buckets in
  let t1 = Core_unix.gettimeofday () in
  printf "  Abstraction built in %.2fs\n\n%!" (t1 -. t0);

  (* Train -- we replicate the training loop to capture raw cfr_state *)
  let cfr_states = [| Cfr_nolimit.create (); Cfr_nolimit.create () |] in
  let util_sum = ref 0.0 in
  let t_train_start = Core_unix.gettimeofday () in

  for iter = 1 to !iterations do
    let (p1_cards, p2_cards, board) = Cfr_nolimit.sample_deal () in
    let p1_buckets =
      Cfr_nolimit.precompute_buckets_equity ~abstraction ~hole_cards:p1_cards ~board
    in
    let p2_buckets =
      Cfr_nolimit.precompute_buckets_equity ~abstraction ~hole_cards:p2_cards ~board
    in
    let traverser = (iter - 1) % 2 in
    let p_invested = [| config.small_blind; config.big_blind |] in
    let p_stack = [|
      config.starting_stack - config.small_blind;
      config.starting_stack - config.big_blind;
    |] in
    let round_start_invested = [| config.small_blind; config.big_blind |] in
    let state : Cfr_nolimit.nl_state = {
      to_act = 0;
      round_idx = 0;
      num_raises = 1;
      current_bet = config.big_blind;
      p_invested;
      p_stack;
      round_start_invested;
      actions_remaining = 2;
    } in
    let value = Cfr_nolimit.mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:"" ~state ~traverser ~cfr_states in
    util_sum := !util_sum +. value;
    match iter % !report_every = 0 with
    | true ->
      let avg_util = !util_sum /. Float.of_int iter in
      let elapsed = Core_unix.gettimeofday () -. t_train_start in
      let rate = Float.of_int iter /. elapsed in
      let n0 = Hashtbl.length cfr_states.(0).regret_sum in
      let n1 = Hashtbl.length cfr_states.(1).regret_sum in
      printf "  [%d/%d] avg_util=%.4f infosets=(%d,%d) %.0f iter/s\n%!"
        iter !iterations avg_util n0 n1 rate
    | false -> ()
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

  (* Save raw cfr_state as association lists (no closures for Marshal
     compatibility across different executables). *)
  printf "\nSaving raw cfr_state to %s...\n%!" !output_file;
  let hashtbl_to_alist tbl =
    Hashtbl.fold tbl ~init:[] ~f:(fun ~key ~data acc -> (key, data) :: acc)
  in
  let data =
    ( hashtbl_to_alist cfr_states.(0).regret_sum
    , hashtbl_to_alist cfr_states.(0).strategy_sum
    , hashtbl_to_alist cfr_states.(1).regret_sum
    , hashtbl_to_alist cfr_states.(1).strategy_sum )
  in
  let oc = Out_channel.create !output_file in
  Marshal.to_channel oc data [];
  Out_channel.close oc;
  let file_size = Int64.to_int_exn (Core_unix.stat !output_file).st_size in
  printf "  File size: %d bytes (%.1f MB)\n%!" file_size
    (Float.of_int file_size /. 1_048_576.0);
  printf "\n=== Done ===\n%!"
