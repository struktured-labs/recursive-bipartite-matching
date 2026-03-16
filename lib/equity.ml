(** Hand equity computation for Texas Hold'em.

    Uses exhaustive enumeration for precise equity calculations on
    complete/near-complete boards, and Monte Carlo sampling for
    preflop/early street equity where full enumeration is intractable.

    The 7-card evaluator selects the best 5-card hand from all
    C(7,5)=21 combinations using {!Hand_eval5}. *)

(* ------------------------------------------------------------------ *)
(* Canonical hand representation                                       *)
(* ------------------------------------------------------------------ *)

type canonical_hand = {
  id : int;
  name : string;
  rank1 : Card.Rank.t;
  rank2 : Card.Rank.t;
  suited : bool;
} [@@deriving sexp]

(** Build the 169 canonical hands.
    Convention: rank1 >= rank2 (by Rank.to_int).
    Pairs: rank1 = rank2, suited = false.
    Suited: rank1 > rank2, suited = true.
    Offsuit: rank1 > rank2, suited = false. *)
let all_canonical_hands =
  let hands = ref [] in
  let id = ref 0 in
  (* Iterate over all rank pairs with r1 >= r2 *)
  List.iter Card.Rank.all ~f:(fun r1 ->
    List.iter Card.Rank.all ~f:(fun r2 ->
      let i1 = Card.Rank.to_int r1 in
      let i2 = Card.Rank.to_int r2 in
      match i1 >= i2 with
      | false -> ()
      | true ->
        match i1 = i2 with
        | true ->
          (* Pocket pair *)
          let name =
            Card.Rank.to_string r1 ^ Card.Rank.to_string r2
          in
          hands := { id = !id; name; rank1 = r1; rank2 = r2; suited = false } :: !hands;
          Int.incr id
        | false ->
          (* Suited *)
          let name_s =
            Card.Rank.to_string r1 ^ Card.Rank.to_string r2 ^ "s"
          in
          hands := { id = !id; name = name_s; rank1 = r1; rank2 = r2; suited = true } :: !hands;
          Int.incr id;
          (* Offsuit *)
          let name_o =
            Card.Rank.to_string r1 ^ Card.Rank.to_string r2 ^ "o"
          in
          hands := { id = !id; name = name_o; rank1 = r1; rank2 = r2; suited = false } :: !hands;
          Int.incr id));
  List.rev !hands

let to_canonical ((c1, c2) : Card.t * Card.t) =
  let i1 = Card.Rank.to_int c1.rank in
  let i2 = Card.Rank.to_int c2.rank in
  let r1, r2, suited =
    match i1 >= i2 with
    | true -> (c1.rank, c2.rank, Card.Suit.equal c1.suit c2.suit)
    | false -> (c2.rank, c1.rank, Card.Suit.equal c1.suit c2.suit)
  in
  let is_pair = Card.Rank.equal r1 r2 in
  (* For pairs, suited is always false in canonical form *)
  let suited = match is_pair with true -> false | false -> suited in
  List.find_exn all_canonical_hands ~f:(fun h ->
    Card.Rank.equal h.rank1 r1
    && Card.Rank.equal h.rank2 r2
    && Bool.equal h.suited suited)

(* ------------------------------------------------------------------ *)
(* Card utilities                                                      *)
(* ------------------------------------------------------------------ *)

let remove_cards deck cards =
  List.filter deck ~f:(fun c ->
    not (List.exists cards ~f:(fun cc -> Card.equal c cc)))

let all_pairs cards =
  let arr = Array.of_list cards in
  let n = Array.length arr in
  let pairs = ref [] in
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      pairs := (arr.(i), arr.(j)) :: !pairs
    done
  done;
  List.rev !pairs

(** Fisher-Yates shuffle on an array. *)
let shuffle_array arr =
  let n = Array.length arr in
  for i = n - 1 downto 1 do
    let j = Random.int (i + 1) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done

(* ------------------------------------------------------------------ *)
(* 7-card hand evaluation via best-of-C(7,5)                           *)
(* ------------------------------------------------------------------ *)

(** All C(7,5) = 21 ways to choose 5 cards from 7.
    Precomputed as an array of tuples for speed. *)
let combinations_7_5 =
  let result = ref [] in
  for i = 0 to 6 do
    for j = i + 1 to 6 do
      for k = j + 1 to 6 do
        for l = k + 1 to 6 do
          for m = l + 1 to 6 do
            result := (i, j, k, l, m) :: !result
          done
        done
      done
    done
  done;
  List.rev !result

(** Evaluate a 7-card hand by finding the best 5-card subset.
    Returns (Hand_rank, tiebreakers) for the best 5-card hand. *)
let evaluate_7 cards =
  let arr = Array.of_list cards in
  List.fold combinations_7_5
    ~init:(Hand_eval5.Hand_rank.High_card, [ 0 ])
    ~f:(fun best_so_far (i, j, k, l, m) ->
      let rank, tb =
        Hand_eval5.evaluate arr.(i) arr.(j) arr.(k) arr.(l) arr.(m)
      in
      let cmp_rank =
        Int.compare
          (Hand_eval5.Hand_rank.to_int rank)
          (Hand_eval5.Hand_rank.to_int (fst best_so_far))
      in
      match cmp_rank > 0 with
      | true -> (rank, tb)
      | false ->
        match cmp_rank = 0 with
        | true ->
          let cmp_tb = List.compare Int.compare tb (snd best_so_far) in
          (match cmp_tb > 0 with
           | true -> (rank, tb)
           | false -> best_so_far)
        | false -> best_so_far)

let compare_7card
    (a1, a2, a3, a4, a5, a6, a7)
    (b1, b2, b3, b4, b5, b6, b7)
  =
  let rank_a, tb_a = evaluate_7 [ a1; a2; a3; a4; a5; a6; a7 ] in
  let rank_b, tb_b = evaluate_7 [ b1; b2; b3; b4; b5; b6; b7 ] in
  let rank_cmp =
    Int.compare
      (Hand_eval5.Hand_rank.to_int rank_a)
      (Hand_eval5.Hand_rank.to_int rank_b)
  in
  match rank_cmp with
  | 0 -> List.compare Int.compare tb_a tb_b
  | n -> n

(** Compare 7-card hands given as lists. *)
let compare_7card_lists h1 h2 =
  let a = Array.of_list h1 in
  let b = Array.of_list h2 in
  compare_7card
    (a.(0), a.(1), a.(2), a.(3), a.(4), a.(5), a.(6))
    (b.(0), b.(1), b.(2), b.(3), b.(4), b.(5), b.(6))

(* ------------------------------------------------------------------ *)
(* matchup_result                                                      *)
(* ------------------------------------------------------------------ *)

let matchup_result ~p1_cards ~p2_cards ~board =
  let (p1a, p1b) = p1_cards in
  let (p2a, p2b) = p2_cards in
  match List.length board with
  | 5 ->
    let b = Array.of_list board in
    let cmp =
      compare_7card
        (p1a, p1b, b.(0), b.(1), b.(2), b.(3), b.(4))
        (p2a, p2b, b.(0), b.(1), b.(2), b.(3), b.(4))
    in
    (match cmp > 0 with
     | true -> `Win
     | false ->
       match cmp < 0 with
       | true -> `Lose
       | false -> `Draw)
  | board_len ->
    (* For incomplete boards, enumerate remaining board cards *)
    let dealt = [ p1a; p1b; p2a; p2b ] @ board in
    let remaining = remove_cards Card.full_deck dealt in
    let cards_needed = 5 - board_len in
    let wins = ref 0 in
    let losses = ref 0 in
    let _draws = ref 0 in
    let rec enumerate_boards chosen rest depth =
      match depth with
      | 0 ->
        let full_board = board @ List.rev chosen in
        let cmp =
          compare_7card_lists ([ p1a; p1b ] @ full_board) ([ p2a; p2b ] @ full_board)
        in
        (match cmp > 0 with
         | true -> Int.incr wins
         | false ->
           match cmp < 0 with
           | true -> Int.incr losses
           | false -> Int.incr _draws)
      | _ ->
        List.iteri rest ~f:(fun i card ->
          let rest' = List.filteri rest ~f:(fun j _ -> j > i) in
          enumerate_boards (card :: chosen) rest' (depth - 1))
    in
    enumerate_boards [] remaining cards_needed;
    let w = !wins in
    let l = !losses in
    (match w > l with
     | true -> `Win
     | false ->
       match w < l with
       | true -> `Lose
       | false -> `Draw)

(* ------------------------------------------------------------------ *)
(* hand_strength                                                       *)
(* ------------------------------------------------------------------ *)

let rec hand_strength ~hole_cards ~board =
  let (h1, h2) = hole_cards in
  let dealt = [ h1; h2 ] @ board in
  let remaining = remove_cards Card.full_deck dealt in
  let board_len = List.length board in
  match board_len with
  | 5 ->
    (* River: enumerate C(remaining,2) opponent hands *)
    let b = Array.of_list board in
    let opponent_hands = all_pairs remaining in
    let wins = ref 0.0 in
    let total = ref 0 in
    List.iter opponent_hands ~f:(fun (o1, o2) ->
      let cmp =
        compare_7card
          (h1, h2, b.(0), b.(1), b.(2), b.(3), b.(4))
          (o1, o2, b.(0), b.(1), b.(2), b.(3), b.(4))
      in
      Int.incr total;
      match cmp > 0 with
      | true -> wins := !wins +. 1.0
      | false ->
        match cmp = 0 with
        | true -> wins := !wins +. 0.5
        | false -> ());
    (match !total with
     | 0 -> 0.5
     | n -> !wins /. Float.of_int n)
  | 4 ->
    (* Turn: enumerate 1 river card, then opponents *)
    let wins = ref 0.0 in
    let total = ref 0 in
    List.iter remaining ~f:(fun river ->
      let full_board = board @ [ river ] in
      let b = Array.of_list full_board in
      let remaining_after =
        List.filter remaining ~f:(fun c -> not (Card.equal c river))
      in
      let opponent_hands = all_pairs remaining_after in
      List.iter opponent_hands ~f:(fun (o1, o2) ->
        let cmp =
          compare_7card
            (h1, h2, b.(0), b.(1), b.(2), b.(3), b.(4))
            (o1, o2, b.(0), b.(1), b.(2), b.(3), b.(4))
        in
        Int.incr total;
        match cmp > 0 with
        | true -> wins := !wins +. 1.0
        | false ->
          match cmp = 0 with
          | true -> wins := !wins +. 0.5
          | false -> ()));
    (match !total with
     | 0 -> 0.5
     | n -> !wins /. Float.of_int n)
  | 3 ->
    (* Flop: enumerate C(remaining,2) = turn+river, then opponents *)
    let remaining_arr = Array.of_list remaining in
    let n_rem = Array.length remaining_arr in
    let wins = ref 0.0 in
    let total = ref 0 in
    for ti = 0 to n_rem - 2 do
      let turn = remaining_arr.(ti) in
      for ri = ti + 1 to n_rem - 1 do
        let river = remaining_arr.(ri) in
        let full_board = board @ [ turn; river ] in
        let b = Array.of_list full_board in
        (* Enumerate opponents from remaining (excluding turn/river) *)
        for oi = 0 to n_rem - 2 do
          match oi = ti || oi = ri with
          | true -> ()
          | false ->
            for oj = oi + 1 to n_rem - 1 do
              match oj = ti || oj = ri with
              | true -> ()
              | false ->
                let o1 = remaining_arr.(oi) in
                let o2 = remaining_arr.(oj) in
                let cmp =
                  compare_7card
                    (h1, h2, b.(0), b.(1), b.(2), b.(3), b.(4))
                    (o1, o2, b.(0), b.(1), b.(2), b.(3), b.(4))
                in
                Int.incr total;
                (match cmp > 0 with
                 | true -> wins := !wins +. 1.0
                 | false ->
                   match cmp = 0 with
                   | true -> wins := !wins +. 0.5
                   | false -> ())
            done
        done
      done
    done;
    (match !total with
     | 0 -> 0.5
     | n -> !wins /. Float.of_int n)
  | _ ->
    (* Preflop (0 board) or other: use Monte Carlo sampling *)
    hand_strength_mc ~hole_cards ~board ~n_samples:20_000

(** Monte Carlo hand strength estimation.
    Randomly samples boards and opponent hands. *)
and hand_strength_mc ~hole_cards ~board ~n_samples =
  let (h1, h2) = hole_cards in
  let dealt = [ h1; h2 ] @ board in
  let remaining = remove_cards Card.full_deck dealt in
  let remaining_arr = Array.of_list remaining in
  let board_len = List.length board in
  let cards_needed = 5 - board_len in
  let wins = ref 0.0 in
  let total = ref 0 in
  for _ = 1 to n_samples do
    (* Shuffle remaining cards *)
    shuffle_array remaining_arr;
    (* Pick board completion cards, then 2 opponent cards *)
    let have_enough = Array.length remaining_arr >= cards_needed + 2 in
    match have_enough with
    | false -> ()
    | true ->
      let full_board =
        board @ Array.to_list (Array.sub remaining_arr ~pos:0 ~len:cards_needed)
      in
      let o1 = remaining_arr.(cards_needed) in
      let o2 = remaining_arr.(cards_needed + 1) in
      let b = Array.of_list full_board in
      let cmp =
        compare_7card
          (h1, h2, b.(0), b.(1), b.(2), b.(3), b.(4))
          (o1, o2, b.(0), b.(1), b.(2), b.(3), b.(4))
      in
      Int.incr total;
      (match cmp > 0 with
       | true -> wins := !wins +. 1.0
       | false ->
         match cmp = 0 with
         | true -> wins := !wins +. 0.5
         | false -> ())
  done;
  (match !total with
   | 0 -> 0.5
   | n -> !wins /. Float.of_int n)

(* ------------------------------------------------------------------ *)
(* equity_distribution                                                 *)
(* ------------------------------------------------------------------ *)

let equity_distribution ~hole_cards ~board ~n_bins =
  let (h1, h2) = hole_cards in
  let dealt = [ h1; h2 ] @ board in
  let remaining = remove_cards Card.full_deck dealt in
  let board_len = List.length board in
  let histogram = Array.create ~len:n_bins 0.0 in
  match board_len with
  | 5 ->
    (* River: single equity value, place in appropriate bin *)
    let eq = hand_strength ~hole_cards ~board in
    let bin = Int.min (n_bins - 1) (Float.to_int (eq *. Float.of_int n_bins)) in
    histogram.(bin) <- 1.0;
    histogram
  | 4 ->
    (* Turn: enumerate 1 remaining card for river *)
    let n_completions = ref 0 in
    List.iter remaining ~f:(fun river ->
      let full_board = board @ [ river ] in
      let eq = hand_strength ~hole_cards ~board:full_board in
      let bin = Int.min (n_bins - 1) (Float.to_int (eq *. Float.of_int n_bins)) in
      histogram.(bin) <- histogram.(bin) +. 1.0;
      Int.incr n_completions);
    let total = Float.of_int !n_completions in
    (match Float.( > ) total 0.0 with
     | true -> Array.iteri histogram ~f:(fun i v -> histogram.(i) <- v /. total)
     | false -> ());
    histogram
  | _ ->
    (* Flop or preflop: use Monte Carlo sampling for board completions *)
    let remaining_arr = Array.of_list remaining in
    let cards_needed = 5 - board_len in
    let n_samples = 2_000 in
    let n_completions = ref 0 in
    for _ = 1 to n_samples do
      shuffle_array remaining_arr;
      let have_enough = Array.length remaining_arr >= cards_needed in
      match have_enough with
      | false -> ()
      | true ->
        let full_board =
          board @ Array.to_list (Array.sub remaining_arr ~pos:0 ~len:cards_needed)
        in
        (* For each sampled board, compute exact equity against all opponents *)
        let eq = hand_strength ~hole_cards ~board:full_board in
        let bin = Int.min (n_bins - 1) (Float.to_int (eq *. Float.of_int n_bins)) in
        histogram.(bin) <- histogram.(bin) +. 1.0;
        Int.incr n_completions
    done;
    let total = Float.of_int !n_completions in
    (match Float.( > ) total 0.0 with
     | true -> Array.iteri histogram ~f:(fun i v -> histogram.(i) <- v /. total)
     | false -> ());
    histogram

(* ------------------------------------------------------------------ *)
(* preflop_equities                                                    *)
(* ------------------------------------------------------------------ *)

(** Compute preflop equity for a single canonical hand.
    Uses Monte Carlo with a single representative suit combo.
    For pairs, uses one specific combo (e.g., AhAs).
    For suited, uses one specific combo (e.g., AhKh).
    For offsuit, uses one specific combo (e.g., AhKd).
    Symmetry of suits guarantees all combos have the same equity. *)
let equity_for_canonical (hand : canonical_hand) =
  let hole_cards =
    match Card.Rank.equal hand.rank1 hand.rank2 with
    | true ->
      (* Pair: pick two fixed suits *)
      ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
       { Card.rank = hand.rank2; suit = Card.Suit.Spades })
    | false ->
      match hand.suited with
      | true ->
        (* Suited: same suit *)
        ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
         { Card.rank = hand.rank2; suit = Card.Suit.Hearts })
      | false ->
        (* Offsuit: different suits *)
        ({ Card.rank = hand.rank1; suit = Card.Suit.Hearts },
         { Card.rank = hand.rank2; suit = Card.Suit.Diamonds })
  in
  (* Use Monte Carlo with enough samples for good convergence *)
  hand_strength_mc ~hole_cards ~board:[] ~n_samples:50_000

let preflop_equities () =
  let n = List.length all_canonical_hands in
  let equities = Array.create ~len:n 0.0 in
  List.iter all_canonical_hands ~f:(fun hand ->
    equities.(hand.id) <- equity_for_canonical hand);
  equities
