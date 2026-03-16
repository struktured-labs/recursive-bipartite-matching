(** Suit isomorphism for 2-card starting hands.

    169 canonical classes: 13 pairs + 78 suited + 78 offsuit. *)

type hand_class = {
  rank1 : Card.Rank.t;
  rank2 : Card.Rank.t;
  suited : bool;
}

let classify (c1 : Card.t) (c2 : Card.t) =
  let r1 = Card.Rank.to_int c1.rank in
  let r2 = Card.Rank.to_int c2.rank in
  let high, low =
    match r1 >= r2 with
    | true -> (c1.rank, c2.rank)
    | false -> (c2.rank, c1.rank)
  in
  let suited = Card.Suit.equal c1.suit c2.suit in
  { rank1 = high; rank2 = low; suited }

(** All 13 ranks in descending order (Ace first). *)
let ranks_desc = List.rev Card.Rank.all

(** All 169 classes: 13 pairs, then 78 suited, then 78 offsuit.
    Within suited/offsuit groups: ordered by high rank desc, then low rank desc. *)
let all_classes =
  let pairs =
    List.map ranks_desc ~f:(fun r -> { rank1 = r; rank2 = r; suited = false })
  in
  let non_pairs =
    let acc = ref [] in
    List.iter ranks_desc ~f:(fun r1 ->
      List.iter ranks_desc ~f:(fun r2 ->
        match Card.Rank.to_int r1 > Card.Rank.to_int r2 with
        | true -> acc := (r1, r2) :: !acc
        | false -> ()));
    List.rev !acc
  in
  let suited =
    List.map non_pairs ~f:(fun (r1, r2) ->
      { rank1 = r1; rank2 = r2; suited = true })
  in
  let offsuit =
    List.map non_pairs ~f:(fun (r1, r2) ->
      { rank1 = r1; rank2 = r2; suited = false })
  in
  pairs @ suited @ offsuit

let canonical_id hc =
  let r1 = Card.Rank.to_int hc.rank1 in
  let r2 = Card.Rank.to_int hc.rank2 in
  match r1 = r2 with
  | true ->
    (* Pair: Ace=14 -> index 0, King=13 -> index 1, ... Two=2 -> index 12 *)
    14 - r1
  | false ->
    (* Non-pair rank indices: map (high, low) to sequential index.
       high ranges 14..3, low ranges (high-1)..2.
       For high=h, low=l: offset within non-pairs is
         sum_{h'=14}^{h+1} (h'-2) + (h-1-l)
       = sum_{k=h+1}^{14}(k-2) + (h-1-l)
       Total non-pairs with high > h: sum from h'=h+1 to 14 of (h'-2)
    *)
    let offset_for_high h =
      (* number of non-pair combos with first rank > h *)
      let count = ref 0 in
      for h' = h + 1 to 14 do
        count := !count + (h' - 2)
      done;
      !count
    in
    let base = offset_for_high r1 in
    let within = r1 - 1 - r2 in
    let non_pair_idx = base + within in
    match hc.suited with
    | true -> 13 + non_pair_idx
    | false -> 13 + 78 + non_pair_idx

let to_string hc =
  let s1 = Card.Rank.to_string hc.rank1 in
  let s2 = Card.Rank.to_string hc.rank2 in
  match Card.Rank.to_int hc.rank1 = Card.Rank.to_int hc.rank2 with
  | true -> s1 ^ s2
  | false ->
    match hc.suited with
    | true -> s1 ^ s2 ^ "s"
    | false -> s1 ^ s2 ^ "o"

let hands_in_class hc =
  let suits = Card.Suit.all in
  match Card.Rank.to_int hc.rank1 = Card.Rank.to_int hc.rank2 with
  | true ->
    (* Pair: C(4,2) = 6 combos *)
    let combos = ref [] in
    List.iter suits ~f:(fun s1 ->
      List.iter suits ~f:(fun s2 ->
        match Card.Suit.compare s1 s2 < 0 with
        | true ->
          combos :=
            ({ Card.rank = hc.rank1; suit = s1 },
             { Card.rank = hc.rank2; suit = s2 })
            :: !combos
        | false -> ()));
    List.rev !combos
  | false ->
    match hc.suited with
    | true ->
      (* Suited: 4 combos (one per suit) *)
      List.map suits ~f:(fun s ->
        ({ Card.rank = hc.rank1; suit = s },
         { Card.rank = hc.rank2; suit = s }))
    | false ->
      (* Offsuit: 4*3 = 12 combos *)
      let combos = ref [] in
      List.iter suits ~f:(fun s1 ->
        List.iter suits ~f:(fun s2 ->
          match Card.Suit.equal s1 s2 with
          | true -> ()
          | false ->
            combos :=
              ({ Card.rank = hc.rank1; suit = s1 },
               { Card.rank = hc.rank2; suit = s2 })
              :: !combos));
      List.rev !combos
