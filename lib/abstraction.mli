(** Per-street card abstraction for Limit Hold'em.

    Groups strategically similar hands into buckets at each street
    (preflop, flop, turn, river) to reduce the game tree size for
    CFR solving.  Supports both equity-based and RBM-distance-based
    clustering. *)

type street = Preflop | Flop | Turn | River [@@deriving sexp, compare]

(** Bucket assignment for a specific street.
    Key format: "preflop:AKs" or "flop:12:Ah5c2d" where 12 is preflop bucket. *)
type bucket_map = (string, int) Hashtbl.Poly.t

(** Partial abstraction: built incrementally per street. *)
type abstraction_partial = {
  street : street;
  n_buckets : int;
  assignments : (int, int) Hashtbl.Poly.t;
      (** canonical_hand_id -> bucket *)
  centroids : float array;
      (** bucket -> average equity *)
}

(** Full multi-street abstraction. *)
type abstraction = {
  preflop_buckets : int;
  flop_buckets : int;
  turn_buckets : int;
  river_buckets : int;
  bucket_map : bucket_map;
}

(** Placeholder config type for limit_holdem dependency.
    Will be replaced by Limit_holdem.config once that module exists. *)
type holdem_config = {
  deck : Card.t list;
  ante : int;
  small_bet : int;
  big_bet : int;
  max_raises : int;
} [@@deriving sexp]

val default_holdem_config : holdem_config

(** Build preflop abstraction using equity-based clustering.
    Groups the 169 canonical hands into [n_buckets] clusters by
    equity similarity.  Uses quantile bucketing for speed. *)
val abstract_preflop_equity
  :  n_buckets:int
  -> abstraction_partial

(** Build preflop abstraction using RBM distance on game trees.
    This is the novel contribution: uses structural tree distance
    rather than scalar equity for clustering.
    NOTE: Requires limit_holdem.ml; currently returns equity-based
    fallback until that module is wired in. *)
val abstract_preflop_rbm
  :  n_buckets:int
  -> config:holdem_config
  -> abstraction_partial

(** Look up the bucket for a hand at a given street.
    For preflop, maps the canonical hand to its bucket.
    For later streets, would use the bucket_map (when implemented). *)
val get_bucket
  :  abstraction_partial
  -> hole_cards:Card.t * Card.t
  -> int

(** Build a complete multi-street abstraction.
    Currently only preflop is implemented; later streets return
    placeholder single-bucket abstractions. *)
val build_abstraction
  :  preflop_buckets:int
  -> flop_buckets:int
  -> turn_buckets:int
  -> river_buckets:int
  -> abstraction

(** Compute EMD between two equity distributions.
    1D Wasserstein distance on histogram bins. *)
val emd_histograms : float array -> float array -> float

(** Sort values by magnitude and assign to buckets by quantile.
    Returns (hand_id -> bucket) mapping and per-bucket centroids. *)
val quantile_bucketing
  :  n_buckets:int
  -> float array
  -> (int, int) Hashtbl.Poly.t * float array
