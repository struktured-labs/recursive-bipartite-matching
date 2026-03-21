module Rank = struct
  type t =
    | Two | Three | Four | Five | Six | Seven | Eight | Nine | Ten
    | Jack | Queen | King | Ace
  [@@deriving sexp, compare, equal, enumerate, hash]

  let to_int = function
    | Two -> 2 | Three -> 3 | Four -> 4 | Five -> 5 | Six -> 6
    | Seven -> 7 | Eight -> 8 | Nine -> 9 | Ten -> 10
    | Jack -> 11 | Queen -> 12 | King -> 13 | Ace -> 14

  (** Zero-based index (0-12) for compact encoding. *)
  let to_index = function
    | Two -> 0 | Three -> 1 | Four -> 2 | Five -> 3 | Six -> 4
    | Seven -> 5 | Eight -> 6 | Nine -> 7 | Ten -> 8
    | Jack -> 9 | Queen -> 10 | King -> 11 | Ace -> 12

  let of_index_exn = function
    | 0 -> Two | 1 -> Three | 2 -> Four | 3 -> Five | 4 -> Six
    | 5 -> Seven | 6 -> Eight | 7 -> Nine | 8 -> Ten
    | 9 -> Jack | 10 -> Queen | 11 -> King | 12 -> Ace
    | n -> failwithf "Rank.of_index_exn: invalid index %d" n ()

  let to_string = function
    | Two -> "2" | Three -> "3" | Four -> "4" | Five -> "5" | Six -> "6"
    | Seven -> "7" | Eight -> "8" | Nine -> "9" | Ten -> "T"
    | Jack -> "J" | Queen -> "Q" | King -> "K" | Ace -> "A"
end

module Suit = struct
  type t = Clubs | Diamonds | Hearts | Spades
  [@@deriving sexp, compare, equal, enumerate, hash]

  let to_int = function
    | Clubs -> 0 | Diamonds -> 1 | Hearts -> 2 | Spades -> 3

  let of_int_exn = function
    | 0 -> Clubs | 1 -> Diamonds | 2 -> Hearts | 3 -> Spades
    | n -> failwithf "Suit.of_int_exn: invalid index %d" n ()

  let to_string = function
    | Clubs -> "c" | Diamonds -> "d" | Hearts -> "h" | Spades -> "s"
end

(* Unboxed int representation: rank_index * 4 + suit_index, range 0..51 *)
type t = int

let create ~rank ~suit = (Rank.to_index rank * 4) + Suit.to_int suit
let rank t = Rank.of_index_exn (t / 4)
let suit t = Suit.of_int_exn (t mod 4)
let to_int t = t
let of_int_exn t =
  match t >= 0 && t <= 51 with
  | true -> t
  | false -> failwithf "Card.of_int_exn: invalid card %d" t ()

let sexp_of_t t =
  let r = rank t in
  let s = suit t in
  Sexp.List [ Rank.sexp_of_t r; Suit.sexp_of_t s ]

let t_of_sexp sexp =
  match sexp with
  | Sexp.List [ r_sexp; s_sexp ] ->
    let r = Rank.t_of_sexp r_sexp in
    let s = Suit.t_of_sexp s_sexp in
    create ~rank:r ~suit:s
  | _ -> of_sexp_error "Card.t_of_sexp: expected (Rank Suit)" sexp

let compare = Int.compare
let equal = Int.equal
let hash = Int.hash
let hash_fold_t = Int.hash_fold_t

let to_string t =
  Rank.to_string (rank t) ^ Suit.to_string (suit t)

let full_deck =
  List.concat_map Suit.all ~f:(fun s ->
    List.map Rank.all ~f:(fun r -> create ~rank:r ~suit:s))

let small_deck ~n_ranks =
  let ranks = List.take Rank.all n_ranks in
  List.concat_map Suit.all ~f:(fun s ->
    List.map ranks ~f:(fun r -> create ~rank:r ~suit:s))
