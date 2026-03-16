(** EMD baseline for Mini Texas Hold'em.

    Computes showdown distributions for 2-hole-card hands against all
    possible 2-card opponent hands, using 5-card evaluation. *)

type deal = {
  p1_cards : Card.t * Card.t;
  community : Card.t list;
}

let compute_distribution ~deck ~p1_cards ~community =
  let (p1a, p1b) = p1_cards in
  let dealt = [ p1a; p1b ] @ community in
  let remaining = Mini_holdem.remove_cards deck dealt in
  let opponent_hands = Mini_holdem.all_pairs remaining in
  let n_opp = List.length opponent_hands in
  match n_opp with
  | 0 ->
    { Emd_baseline.win_prob = 0.0; lose_prob = 0.0; draw_prob = 1.0; ev = 0.0 }
  | _ ->
    let wins = ref 0 in
    let losses = ref 0 in
    let draws = ref 0 in
    List.iter opponent_hands ~f:(fun (opp1, opp2) ->
      match community with
      | [ c1; c2; c3 ] ->
        let cmp =
          Hand_eval5.compare_hands5
            (p1a, p1b, c1, c2, c3)
            (opp1, opp2, c1, c2, c3)
        in
        (match cmp > 0 with
         | true -> Int.incr wins
         | false ->
           (match cmp < 0 with
            | true -> Int.incr losses
            | false -> Int.incr draws))
      | _ -> Int.incr draws);
    let n = Float.of_int n_opp in
    let w = Float.of_int !wins in
    let l = Float.of_int !losses in
    let d = Float.of_int !draws in
    let ev = (w -. l) /. n in
    { Emd_baseline.win_prob = w /. n
    ; lose_prob = l /. n
    ; draw_prob = d /. n
    ; ev
    }
