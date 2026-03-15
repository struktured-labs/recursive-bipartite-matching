module Hand_rank = struct
  type t =
    | High_card
    | Pair
    | Flush
    | Straight
    | Three_of_a_kind
  [@@deriving sexp, compare, equal]

  let to_int = function
    | High_card -> 0
    | Pair -> 1
    | Flush -> 2
    | Straight -> 3
    | Three_of_a_kind -> 4
end

let is_flush (c1 : Card.t) (c2 : Card.t) (c3 : Card.t) =
  Card.Suit.equal c1.suit c2.suit && Card.Suit.equal c2.suit c3.suit

let is_straight ranks =
  let sorted = List.sort ranks ~compare:Int.compare in
  match sorted with
  | [ a; b; c ] ->
    (match b - a = 1 && c - b = 1 with
     | true -> true
     | false ->
       (* Ace-low wrap: A-2-3 = ranks 14, 2, 3 *)
       match a, b, c with
       | 2, 3, 14 -> true
       | _ -> false)
  | _ -> false

let evaluate (c1 : Card.t) (c2 : Card.t) (c3 : Card.t) =
  let r1 = Card.Rank.to_int c1.rank in
  let r2 = Card.Rank.to_int c2.rank in
  let r3 = Card.Rank.to_int c3.rank in
  let ranks = [ r1; r2; r3 ] in
  let sorted = List.sort ranks ~compare:(fun a b -> Int.compare b a) in
  let flush = is_flush c1 c2 c3 in
  let straight = is_straight ranks in
  (* Check for three of a kind *)
  match r1 = r2 && r2 = r3 with
  | true -> (Hand_rank.Three_of_a_kind, sorted)
  | false ->
    (* Check for pair *)
    let pair_rank, kickers =
      match r1 = r2 with
      | true -> (Some r1, [ r3 ])
      | false ->
        (match r2 = r3 with
         | true -> (Some r2, [ r1 ])
         | false ->
           (match r1 = r3 with
            | true -> (Some r1, [ r2 ])
            | false -> (None, [])))
    in
    (match pair_rank with
     | Some pr ->
       let kickers_sorted = List.sort kickers ~compare:(fun a b -> Int.compare b a) in
       (Pair, pr :: kickers_sorted)
     | None ->
       (match straight with
        | true ->
          (* For ace-low straight, tiebreaker is 3 (not ace) *)
          let tb =
            match List.sort ranks ~compare:Int.compare with
            | [ 2; 3; 14 ] -> [ 3; 2; 1 ]
            | _ -> sorted
          in
          (Straight, tb)
        | false ->
          (match flush with
           | true -> (Flush, sorted)
           | false -> (High_card, sorted))))

let compare_hands (a1, a2, a3) (b1, b2, b3) =
  let rank_a, tb_a = evaluate a1 a2 a3 in
  let rank_b, tb_b = evaluate b1 b2 b3 in
  let rank_cmp = Int.compare (Hand_rank.to_int rank_a) (Hand_rank.to_int rank_b) in
  match rank_cmp with
  | 0 -> List.compare Int.compare tb_a tb_b
  | n -> n
