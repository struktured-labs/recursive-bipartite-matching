(** Playing cards for poker — unboxed int representation (0..51). *)

module Rank : sig
  type t =
    | Two | Three | Four | Five | Six | Seven | Eight | Nine | Ten
    | Jack | Queen | King | Ace
  [@@deriving sexp, compare, equal, enumerate, hash]

  val to_int : t -> int
  (** Card value (2..14). *)

  val to_index : t -> int
  (** Zero-based index (0..12) for compact encoding. *)

  val of_index_exn : int -> t
  (** Inverse of [to_index]. Raises on out-of-range. *)

  val to_string : t -> string
end

module Suit : sig
  type t = Clubs | Diamonds | Hearts | Spades
  [@@deriving sexp, compare, equal, enumerate, hash]

  val to_int : t -> int
  (** Suit index (0..3). *)

  val of_int_exn : int -> t
  (** Inverse of [to_int]. Raises on out-of-range. *)

  val to_string : t -> string
end

type t = private int
[@@deriving sexp, compare, equal, hash]

val create : rank:Rank.t -> suit:Suit.t -> t
val rank : t -> Rank.t
val suit : t -> Suit.t
val to_int : t -> int
val of_int_exn : int -> t
val to_string : t -> string

(** Full 52-card deck *)
val full_deck : t list

(** Deck of n ranks (lowest n) x 4 suits, for scaled-down games *)
val small_deck : n_ranks:int -> t list
