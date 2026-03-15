(** Earth Mover's Distance baseline for game tree abstraction.

    Implements the standard EMD-based hand abstraction approach used in
    poker AI (Gilpin & Sandholm 2006, Ganzfried & Sandholm 2014):

    1. For each deal (hole card + community), compute a hand strength
       distribution: the histogram of showdown outcomes (win/draw/lose)
       against all possible opponent hands from the remaining deck.

    2. Use EMD (1D Wasserstein distance) between these distributions as
       the distance metric between deals.

    3. Cluster deals using agglomerative clustering (reusing {!Ev_graph}).

    4. Compare abstraction quality against the recursive bipartite matching
       distance at equivalent compression levels. *)

(** Distribution of showdown outcomes for a deal. *)
type hand_distribution = {
  win_prob : float;   (** fraction of opponent hands we beat *)
  lose_prob : float;  (** fraction of opponent hands that beat us *)
  draw_prob : float;  (** fraction of opponent hands we tie *)
  ev : float;         (** expected value in chips (from showdown only) *)
} [@@deriving sexp]

(** Compute the showdown distribution for player 1 holding [p1_card]
    against all possible opponent cards from [deck], given [community]
    cards.  The [deck] should be the full deck minus dealt cards. *)
val compute_distribution
  :  deck:Card.t list
  -> p1_card:Card.t
  -> community:Card.t list
  -> hand_distribution

(** EMD (1D Wasserstein) distance between two 3-bin distributions.
    For ordered bins (lose < draw < win), EMD equals the L1 distance
    between cumulative distribution functions:
    {[
      |cdf1(lose) - cdf2(lose)| + |cdf1(lose+draw) - cdf2(lose+draw)|
    ]} *)
val emd_distance : hand_distribution -> hand_distribution -> float

(** Scalar EV distance: simply [|ev1 - ev2|].
    This is the simplest possible baseline (hand strength bucketing). *)
val ev_distance : hand_distribution -> hand_distribution -> float

(** A deal: player 1's hole card paired with the community cards. *)
type deal = {
  p1_card : Card.t;
  community : Card.t list;
}

(** Compute hand distributions for all deals. *)
val compute_all_distributions
  :  config:Rhode_island.config
  -> deals:deal list
  -> hand_distribution list

(** Compute pairwise EMD distance matrix for a list of distributions. *)
val pairwise_emd_matrix : hand_distribution list -> Ev_graph.dist_matrix

(** Compute pairwise scalar EV distance matrix. *)
val pairwise_ev_matrix : hand_distribution list -> Ev_graph.dist_matrix

(** Cluster deals using EMD distance.

    Runs single-linkage agglomerative clustering (same algorithm as
    {!Ev_graph.compress}) on the EMD distance matrix.

    Returns (clusters, distance_matrix) where each cluster is a list
    of (original_index, hand_distribution) pairs. *)
type emd_cluster = {
  member_indices : int list;
  centroid : hand_distribution;
  diameter : float;
}

type emd_clustering = {
  clusters : emd_cluster list;
  epsilon : float;
  num_original : int;
}

val cluster_by_emd
  :  epsilon:float
  -> hand_distribution list
  -> emd_clustering

val cluster_by_ev
  :  epsilon:float
  -> hand_distribution list
  -> emd_clustering

(** Compute max EV error for an EMD clustering: the maximum absolute
    difference between any member's EV and its cluster centroid's EV. *)
val max_ev_error : hand_distribution list -> emd_clustering -> float

(** Comparison report: for the same number of clusters, compare
    max EV error between RBM and EMD abstractions.

    Takes a list of game trees (one per deal, same order as deals)
    and runs both methods at multiple compression levels. *)
val comparison_report
  :  config:Rhode_island.config
  -> deals:deal list
  -> trees:Rhode_island.Node_label.t Tree.t list
  -> ?rbm_precomputed:Ev_graph.dist_matrix
  -> unit
  -> string
