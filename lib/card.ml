module Rank = struct
  type t =
    | Two | Three | Four | Five | Six | Seven | Eight | Nine | Ten
    | Jack | Queen | King | Ace
  [@@deriving sexp, compare, equal, enumerate, hash]

  let to_int = function
    | Two -> 2 | Three -> 3 | Four -> 4 | Five -> 5 | Six -> 6
    | Seven -> 7 | Eight -> 8 | Nine -> 9 | Ten -> 10
    | Jack -> 11 | Queen -> 12 | King -> 13 | Ace -> 14

  let to_string = function
    | Two -> "2" | Three -> "3" | Four -> "4" | Five -> "5" | Six -> "6"
    | Seven -> "7" | Eight -> "8" | Nine -> "9" | Ten -> "T"
    | Jack -> "J" | Queen -> "Q" | King -> "K" | Ace -> "A"
end

module Suit = struct
  type t = Clubs | Diamonds | Hearts | Spades
  [@@deriving sexp, compare, equal, enumerate, hash]

  let to_string = function
    | Clubs -> "c" | Diamonds -> "d" | Hearts -> "h" | Spades -> "s"
end

type t = { rank : Rank.t; suit : Suit.t }
[@@deriving sexp, compare, equal, hash]

let to_string { rank; suit } =
  Rank.to_string rank ^ Suit.to_string suit

let full_deck =
  List.concat_map Suit.all ~f:(fun suit ->
    List.map Rank.all ~f:(fun rank -> { rank; suit }))

let small_deck ~n_ranks =
  let ranks = List.take Rank.all n_ranks in
  List.concat_map Suit.all ~f:(fun suit ->
    List.map ranks ~f:(fun rank -> { rank; suit }))
