(** Tree merge operation induced by the recursive bipartite matching distance.

    Given two trees and their optimal matching, produces a representative
    tree that captures their shared structure. Matched children are recursively
    merged; unmatched children are optionally kept or dropped. *)

(** How to handle unmatched (phantom-matched) children *)
type phantom_policy =
  | Drop      (** Discard unmatched children *)
  | Keep      (** Keep unmatched children in the merged tree *)
[@@deriving sexp]

type config = {
  phantom_policy : phantom_policy;
  distance_config : Distance.config;
}

val default_config : config

(** [merge t1 t2] produces a representative tree capturing shared structure.
    Leaf values are averaged (weighted by subtree probability mass). *)
val merge : config:config -> 'a Tree.t -> 'a Tree.t -> 'a Tree.t

(** [merge_weighted ~w1 ~w2 t1 t2] merges with explicit weights.
    Leaf values become (w1 * v1 + w2 * v2) / (w1 + w2). *)
val merge_weighted : config:config -> w1:float -> w2:float -> 'a Tree.t -> 'a Tree.t -> 'a Tree.t
