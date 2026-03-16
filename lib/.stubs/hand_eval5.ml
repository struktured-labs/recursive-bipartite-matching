(** 5-card poker hand evaluation.

    Standard poker rankings: straight flush > four of a kind > full house >
    flush > straight > three of a kind > two pair > one pair > high card.

    Supports ace-low straights (A-2-3-4-5 = "wheel"). *)

module Hand_rank = struct
  type t =
    | High_card
    | One_pair
    | Two_pair
    | Three_of_a_kind
    | Straight
    | Flush
    | Full_house
    | Four_of_a_kind
    | Straight_flush
  [@@deriving sexp, compare, equal]

  let to_int = function
    | High_card -> 0
    | One_pair -> 1
    | Two_pair -> 2
    | Three_of_a_kind -> 3
    | Straight -> 4
    | Flush -> 5
    | Full_house -> 6
    | Four_of_a_kind -> 7
    | Straight_flush -> 8

  let to_string = function
    | High_card -> "high_card"
    | One_pair -> "one_pair"
    | Two_pair -> "two_pair"
    | Three_of_a_kind -> "three_of_a_kind"
    | Straight -> "straight"
    | Flush -> "flush"
    | Full_house -> "full_house"
    | Four_of_a_kind -> "four_of_a_kind"
    | Straight_flush -> "straight_flush"
end

(** Count occurrences of each rank. Returns list of (count, rank_int)
    sorted by count descending, then rank descending. *)
let rank_counts ranks =
  let tbl = Hashtbl.create (module Int) in
  List.iter ranks ~f:(fun r ->
    Hashtbl.update tbl r ~f:(function
      | None -> 1
      | Some n -> n + 1));
  Hashtbl.to_alist tbl
  |> List.sort ~compare:(fun (r1, c1) (r2, c2) ->
    (* Sort by count descending, then rank descending *)
    let cc = Int.compare c2 c1 in
    match cc with
    | 0 -> Int.compare r2 r1
    | n -> n)

let is_flush (c1 : Card.t) (c2 : Card.t) (c3 : Card.t) (c4 : Card.t) (c5 : Card.t) =
  Card.Suit.equal c1.suit c2.suit
  && Card.Suit.equal c2.suit c3.suit
  && Card.Suit.equal c3.suit c4.suit
  && Card.Suit.equal c4.suit c5.suit

(** Check if 5 sorted ranks form a straight. Returns Some high_card if yes. *)
let check_straight sorted_ranks =
  match sorted_ranks with
  | [ a; b; c; d; e ] ->
    (* Normal straight: consecutive *)
    (match b - a = 1 && c - b = 1 && d - c = 1 && e - d = 1 with
     | true -> Some e
     | false ->
       (* Ace-low straight (wheel): A-2-3-4-5 = [2;3;4;5;14] *)
       match a, b, c, d, e with
       | 2, 3, 4, 5, 14 -> Some 5  (* 5 is the high card of the wheel *)
       | _ -> None)
  | _ -> None

let evaluate (c1 : Card.t) (c2 : Card.t) (c3 : Card.t) (c4 : Card.t) (c5 : Card.t) =
  let r1 = Card.Rank.to_int c1.rank in
  let r2 = Card.Rank.to_int c2.rank in
  let r3 = Card.Rank.to_int c3.rank in
  let r4 = Card.Rank.to_int c4.rank in
  let r5 = Card.Rank.to_int c5.rank in
  let ranks = [ r1; r2; r3; r4; r5 ] in
  let sorted = List.sort ranks ~compare:Int.compare in
  let flush = is_flush c1 c2 c3 c4 c5 in
  let straight = check_straight sorted in
  let counts = rank_counts ranks in
  (* Extract the grouping pattern *)
  let count_pattern = List.map counts ~f:snd in
  match count_pattern with
  (* Four of a kind: [4; 1] *)
  | [ 4; 1 ] ->
    let quad_rank = fst (List.hd_exn counts) in
    let kicker = fst (List.nth_exn counts 1) in
    (Hand_rank.Four_of_a_kind, [ quad_rank; kicker ])
  (* Full house: [3; 2] *)
  | [ 3; 2 ] ->
    let trips_rank = fst (List.hd_exn counts) in
    let pair_rank = fst (List.nth_exn counts 1) in
    (Full_house, [ trips_rank; pair_rank ])
  (* Three of a kind: [3; 1; 1] *)
  | [ 3; 1; 1 ] ->
    let trips_rank = fst (List.hd_exn counts) in
    let kickers = List.filter_map counts ~f:(fun (r, c) ->
      match c with 1 -> Some r | _ -> None)
      |> List.sort ~compare:(fun a b -> Int.compare b a)
    in
    (Three_of_a_kind, trips_rank :: kickers)
  (* Two pair: [2; 2; 1] *)
  | [ 2; 2; 1 ] ->
    let pairs = List.filter_map counts ~f:(fun (r, c) ->
      match c with 2 -> Some r | _ -> None)
      |> List.sort ~compare:(fun a b -> Int.compare b a)
    in
    let kicker = List.find_map_exn counts ~f:(fun (r, c) ->
      match c with 1 -> Some r | _ -> None) in
    (Two_pair, pairs @ [ kicker ])
  (* One pair: [2; 1; 1; 1] *)
  | [ 2; 1; 1; 1 ] ->
    let pair_rank = fst (List.hd_exn counts) in
    let kickers = List.filter_map counts ~f:(fun (r, c) ->
      match c with 1 -> Some r | _ -> None)
      |> List.sort ~compare:(fun a b -> Int.compare b a)
    in
    (One_pair, pair_rank :: kickers)
  (* No groups: high card, straight, flush, or straight flush *)
  | _ ->
    (match straight, flush with
     | Some high, true ->
       (Straight_flush, [ high ])
     | Some high, false ->
       (Hand_rank.Straight, [ high ])
     | None, true ->
       let desc = List.sort ranks ~compare:(fun a b -> Int.compare b a) in
       (Flush, desc)
     | None, false ->
       let desc = List.sort ranks ~compare:(fun a b -> Int.compare b a) in
       (High_card, desc))

let compare_hands5 (a1, a2, a3, a4, a5) (b1, b2, b3, b4, b5) =
  let rank_a, tb_a = evaluate a1 a2 a3 a4 a5 in
  let rank_b, tb_b = evaluate b1 b2 b3 b4 b5 in
  let rank_cmp = Int.compare (Hand_rank.to_int rank_a) (Hand_rank.to_int rank_b) in
  match rank_cmp with
  | 0 -> List.compare Int.compare tb_a tb_b
  | n -> n
