(** Labeled rooted trees with payoff-valued leaves.

    The fundamental data structure for recursive bipartite matching distance.
    Children are unordered — the distance function finds the optimal alignment. *)

type 'a t =
  | Leaf of { value : float; label : 'a }
  | Node of { children : 'a t list; label : 'a }
[@@deriving sexp, compare]

val leaf : label:'a -> value:float -> 'a t
val node : label:'a -> children:'a t list -> 'a t

(** Number of nodes (internal + leaves) *)
val size : _ t -> int

(** Depth of deepest leaf *)
val depth : _ t -> int

(** Number of leaves *)
val num_leaves : _ t -> int

(** Map over labels *)
val map_label : 'a t -> f:('a -> 'b) -> 'b t

(** Fold over all leaf values *)
val fold_leaves : _ t -> init:'b -> f:('b -> float -> 'b) -> 'b

(** Expected value: average of all leaf values *)
val ev : _ t -> float
