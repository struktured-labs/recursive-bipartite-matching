(** Action abstraction sweep: test how many bet sizes survive RBM clustering
    at different epsilon values and game contexts.

    Usage:
      opam exec -- dune exec bin/action_sweep.exe
      opam exec -- dune exec bin/action_sweep.exe -- --epsilon 0.05 --candidates 20 *)

open Rbm

let () =
  let epsilon = ref 0.1 in
  let n_candidates = ref 12 in
  let n_sample_hands = ref 10 in
  let big_blind = ref 100 in

  let args = [
    ("--epsilon", Arg.Set_float epsilon,
     "FLOAT  RBM distance threshold for merging (default: 0.1)");
    ("--candidates", Arg.Set_int n_candidates,
     "N  Number of candidate bet sizes (default: 12)");
    ("--sample-hands", Arg.Set_int n_sample_hands,
     "N  Number of sample hands for averaging (default: 10)");
    ("--big-blind", Arg.Set_int big_blind,
     "N  Big blind size (default: 100)");
  ] in
  Arg.parse args (fun _ -> ())
    "action_sweep [--epsilon F] [--candidates N] [--sample-hands N]";

  (* Generate candidate fractions *)
  let candidate_fracs =
    match !n_candidates with
    | n when n <= 5 -> [ 0.33; 0.5; 1.0; 1.5; 2.0 ]
    | n when n <= 8 -> [ 0.25; 0.33; 0.5; 0.75; 1.0; 1.5; 2.0; 3.0 ]
    | n when n <= 12 ->
      [ 0.1; 0.2; 0.25; 0.33; 0.5; 0.67; 0.75; 1.0; 1.25; 1.5; 2.0; 3.0 ]
    | _ ->
      List.init !n_candidates ~f:(fun i ->
        0.1 +. Float.of_int i *. (5.0 -. 0.1) /. Float.of_int (!n_candidates - 1))
  in

  printf "=== Action Abstraction Sweep ===\n\n";
  printf "  Epsilon:         %.3f\n" !epsilon;
  printf "  Candidates:      %d [%s]\n" (List.length candidate_fracs)
    (String.concat ~sep:", " (List.map candidate_fracs ~f:(sprintf "%.2f")));
  printf "  Sample hands:    %d\n" !n_sample_hands;
  printf "  Big blind:       %d\n\n" !big_blind;

  (* Generate sample hands — deal random hands for diversity *)
  printf "Building %d sample hands...\n%!" !n_sample_hands;
  let sample_hands =
    List.init !n_sample_hands ~f:(fun _ ->
      let (h, _, _) = Compact_cfr.sample_deal () in h)
  in
  printf "  Generated %d random sample hands\n\n" (List.length sample_hands);

  (* Sweep contexts *)
  let pot_values = [ 2 * !big_blind; 4 * !big_blind; 10 * !big_blind;
                     20 * !big_blind; 50 * !big_blind ] in
  let stack_values = [ 20 * !big_blind; 50 * !big_blind; 100 * !big_blind;
                       200 * !big_blind ] in

  printf "%-8s  %-8s  %-8s  %-8s  %-10s  %s\n"
    "Street" "Pot/BB" "Stack/BB" "Raises" "Surviving" "Centroids";
  printf "%s\n" (String.make 80 '-');

  let total_contexts = ref 0 in
  let total_surviving = ref 0 in

  List.iter [ 1; 2; 3 ] ~f:(fun street ->
    let board_visible = List.take Card.full_deck
      (match street with 1 -> 3 | 2 -> 4 | _ -> 5) in
    List.iter pot_values ~f:(fun pot ->
      List.iter stack_values ~f:(fun effective_stack ->
        match effective_stack > pot / 2 with  (* skip unreasonable combos *)
        | false -> ()
        | true ->
          let clusters =
            Action_abstraction.cluster_bet_sizes
              ~pot ~effective_stack
              ~candidate_fracs
              ~epsilon:!epsilon
              ~sample_hands ~board_visible ()
          in
          let n_surviving = List.length clusters in
          let centroids = List.map clusters ~f:(fun c ->
            sprintf "%.2f" c.centroid_frac) in
          let street_name = match street with
            | 1 -> "flop" | 2 -> "turn" | _ -> "river" in
          printf "%-8s  %-8d  %-8d  %-8d  %-10d  [%s]\n"
            street_name (pot / !big_blind) (effective_stack / !big_blind)
            0 n_surviving (String.concat ~sep:", " centroids);
          Int.incr total_contexts;
          total_surviving := !total_surviving + n_surviving)));

  printf "\n=== Summary ===\n";
  printf "  Contexts:            %d\n" !total_contexts;
  printf "  Avg surviving sizes: %.1f / %d candidates\n"
    (Float.of_int !total_surviving /. Float.of_int (Int.max 1 !total_contexts))
    (List.length candidate_fracs);
  printf "  Epsilon:             %.3f\n" !epsilon;

  (* Multi-epsilon sweep *)
  printf "\n=== Epsilon Sweep (flop, pot=10bb, stack=100bb) ===\n\n";
  let board_visible = List.take Card.full_deck 3 in
  let pot = 10 * !big_blind in
  let effective_stack = 100 * !big_blind in
  printf "%-10s  %-10s  %-10s  %s\n" "Epsilon" "Surviving" "Max Diam" "Centroids";
  printf "%s\n" (String.make 70 '-');

  List.iter [ 0.01; 0.02; 0.05; 0.1; 0.2; 0.5; 1.0; 2.0 ] ~f:(fun eps ->
    let clusters =
      Action_abstraction.cluster_bet_sizes
        ~pot ~effective_stack ~candidate_fracs
        ~epsilon:eps ~sample_hands ~board_visible ()
    in
    let max_diam = List.fold clusters ~init:0.0 ~f:(fun acc c ->
      Float.max acc c.diameter) in
    let centroids = List.map clusters ~f:(fun c ->
      sprintf "%.2f" c.centroid_frac) in
    printf "%-10.3f  %-10d  %-10.4f  [%s]\n"
      eps (List.length clusters) max_diam
      (String.concat ~sep:", " centroids));

  printf "\n=== Done ===\n"
