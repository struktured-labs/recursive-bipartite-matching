(** Online self-play learner for Rhode Island Hold'em.

    Builds an EV graph incrementally through gameplay. Each game generates
    a game tree that is compared against existing clusters. Close matches
    (d < epsilon) are merged into the matching cluster; distant trees
    create new clusters. Strategy selection uses historical action
    distributions from matched clusters.

    This implements the online learning loop described in Section 8 of
    WRITEUP.md: the EV graph as a living model built dynamically through
    self-play. *)

(** Configuration for the online learner. *)
type config = {
  game_config : Rhode_island.config;
  epsilon : float;          (** Distance threshold for merging into existing cluster *)
  community : Card.t list;  (** Fixed community cards, or [] for random dealing *)
  num_games : int;          (** Total games to play *)
  report_interval : int;    (** Print stats every N games *)
  merge_interval : int;     (** Attempt inter-cluster merges every N games *)
  distance_config : Distance.config;  (** Distance metric configuration *)
}

(** Running statistics for the learner. *)
type stats = {
  games_played : int;
  clusters_created : int;
  clusters_merged : int;
  cache_hits : int;         (** Reused existing cluster strategy *)
  cache_misses : int;       (** Created new cluster *)
  ev_graph_size : int;      (** Current number of clusters *)
}

(** A snapshot of convergence metrics at a point in time. *)
type snapshot = {
  game_number : int;
  num_clusters : int;
  cache_hit_rate : float;
  compression_ratio : float;
  new_cluster_rate : float;   (** Fraction of recent games creating clusters *)
}

(** [default_config ~game_config ~community] returns a sensible default
    configuration for online learning with the given game setup. *)
val default_config
  :  game_config:Rhode_island.config
  -> community:Card.t list
  -> config

(** [run ~config] plays [config.num_games] games of self-play, building
    the EV graph incrementally. Returns final statistics. *)
val run : config:config -> stats

(** [run_exn ~config] like [run] but raises on configuration errors. *)
val run_exn : config:config -> stats

(** [run_with_report ~config] plays games and prints periodic progress
    reports including convergence metrics. *)
val run_with_report : config:config -> unit

(** [run_with_snapshots ~config] plays games and returns both final stats
    and a list of convergence snapshots taken at each report interval. *)
val run_with_snapshots : config:config -> stats * snapshot list
