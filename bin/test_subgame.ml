(** Quick sanity test for the subgame module. *)

open Rbm

let () =
  let config = Nolimit_holdem.short_stack_config in
  printf "=== Enumerate preflop histories (short stack config) ===\n%!";
  let histories = Subgame.enumerate_preflop_histories ~config () in
  printf "Found %d histories:\n%!" (List.length histories);
  List.iter (List.take histories 20) ~f:(fun h -> printf "  \"%s\"\n%!" h);
  (match List.length histories > 20 with
   | true -> printf "  ... and %d more\n%!" (List.length histories - 20)
   | false -> ());

  printf "\n=== Reconstruct state for first few histories ===\n%!";
  List.iter (List.take histories 5) ~f:(fun h ->
    let state = Subgame.reconstruct_state ~config ~preflop_history:h in
    printf "  \"%s\" -> round=%d invested=[%d,%d] stacks=[%d,%d] to_act=%d\n%!"
      h state.round_idx state.p_invested.(0) state.p_invested.(1)
      state.p_stack.(0) state.p_stack.(1) state.to_act);

  printf "\n=== subgame_key_to_string ===\n%!";
  let key : Subgame.subgame_key = { preflop_history = "cc"; flop_cluster = 3 } in
  printf "  %s\n%!" (Subgame.subgame_key_to_string key);

  printf "\n=== Cluster flops (5 flops, epsilon=1.0) ===\n%!";
  let result = Subgame.cluster_flops ~epsilon:1.0 ~n_sample_hands:2
      ~config ~n_flops:5 () in
  List.iter result ~f:(fun (flop, cid) ->
    let flop_str = String.concat ~sep:" " (List.map flop ~f:Card.to_string) in
    printf "  flop=[%s] cluster=%d\n%!" flop_str cid);

  printf "\nAll tests passed.\n%!"
