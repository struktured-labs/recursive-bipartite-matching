(** 7-card poker hand evaluation: best 5 of 7.

    Enumerates all C(7,5) = 21 five-card subsets, evaluates each with
    Hand_eval5, returns the best.  Simple and correct. *)

(** Generate all C(n,5) combinations of 5 elements from a list. *)
let combinations5 cards =
  let arr = Array.of_list cards in
  let n = Array.length arr in
  let results = ref [] in
  for i = 0 to n - 5 do
    for j = i + 1 to n - 4 do
      for k = j + 1 to n - 3 do
        for l = k + 1 to n - 2 do
          for m = l + 1 to n - 1 do
            results := (arr.(i), arr.(j), arr.(k), arr.(l), arr.(m)) :: !results
          done
        done
      done
    done
  done;
  !results

(** Compare two evaluated hands: (rank, tiebreakers). *)
let compare_evaluated (rank_a, tb_a) (rank_b, tb_b) =
  let rank_cmp =
    Int.compare
      (Hand_eval5.Hand_rank.to_int rank_a)
      (Hand_eval5.Hand_rank.to_int rank_b)
  in
  match rank_cmp with
  | 0 -> List.compare Int.compare tb_a tb_b
  | n -> n

let evaluate7 cards =
  let len = List.length cards in
  (match len = 7 with
   | true -> ()
   | false -> failwithf "Hand_eval7.evaluate7: expected 7 cards, got %d" len ());
  let combos = combinations5 cards in
  let evaluated =
    List.map combos ~f:(fun (c1, c2, c3, c4, c5) ->
      Hand_eval5.evaluate c1 c2 c3 c4 c5)
  in
  List.fold evaluated ~init:(List.hd_exn evaluated)
    ~f:(fun best current ->
      match compare_evaluated current best > 0 with
      | true -> current
      | false -> best)

let compare_hands7 hand1 hand2 =
  let eval1 = evaluate7 hand1 in
  let eval2 = evaluate7 hand2 in
  compare_evaluated eval1 eval2
