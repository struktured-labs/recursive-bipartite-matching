(** Playing cards for poker. *)

module Rank : sig
  type t =
    | Two | Three | Four | Five | Six | Seven | Eight | Nine | Ten
    | Jack | Queen | King | Ace
  [@@deriving sexp, compare, equal, enumerate, hash]

  val to_int : t -> int
  val to_string : t -> string
end

module Suit : sig
  type t = Clubs | Diamonds | Hearts | Spades
  [@@deriving sexp, compare, equal, enumerate, hash]

  val to_string : t -> string
end

type t = { rank : Rank.t; suit : Suit.t }
[@@deriving sexp, compare, equal, hash]

val to_string : t -> string

(** Full 52-card deck *)
val full_deck : t list

(** Deck of n ranks (lowest n) x 4 suits, for scaled-down games *)
val small_deck : n_ranks:int -> t list
