type config = {
  game_config : Rhode_island.config;
  epsilon : float;
  community : Card.t list;
  num_games : int;
  report_interval : int;
  merge_interval : int;
  distance_config : Distance.config;
}

type stats = {
  games_played : int;
  clusters_created : int;
  clusters_merged : int;
  cache_hits : int;
  cache_misses : int;
  ev_graph_size : int;
}

type snapshot = {
  game_number : int;
  num_clusters : int;
  cache_hit_rate : float;
  compression_ratio : float;
  new_cluster_rate : float;
}

(** A lightweight online cluster.
    The representative is the FIRST member's tree (never modified) to keep
    distance computation cost constant. We track weighted EV separately. *)
type online_cluster = {
  representative : Rhode_island.Node_label.t Tree.t;  (** first member, immutable *)
  rep_ev : float;                   (** cached EV of representative *)
  weighted_ev : float;              (** running weighted average EV *)
  member_count : int;               (** number of trees assigned *)
  diameter : float;                 (** max distance from any member to representative *)
}

(** Cache entry: maps a tree fingerprint to the cluster index it belongs to.
    Only stores confirmed hits (distance < epsilon). *)
type cache_entry = {
  cluster_idx : int;
  distance : float;
  cluster_count : int;  (** number of clusters when entry was created *)
}

(** Mutable state for the online learning loop. *)
type learner_state = {
  mutable clusters : online_cluster list;
  mutable total_trees_seen : int;
  mutable clusters_created : int;
  mutable clusters_merged : int;
  mutable cache_hits : int;
  mutable cache_misses : int;
  mutable recent_misses : int;
  mutable recent_games : int;
  (** Distance cache: maps (tree_size, tree_ev_quantized) -> cache_entry.
      Only stores confirmed hits (d < epsilon). Invalidated when cluster
      count changes. *)
  distance_cache : (int * int * int, cache_entry) Hashtbl.t;
}

(** Quantize EV to an integer key for hashing. Resolution: 0.1 *)
let quantize_ev ev = Float.iround_nearest_exn (ev *. 10.0)

let default_config ~game_config ~community =
  { game_config
  ; epsilon = 200.0
  ; community
  ; num_games = 1000
  ; report_interval = 100
  ; merge_interval = 200
  ; distance_config = Distance.default_config
  }

(** Shuffle the first [k] elements of [arr] using Fisher-Yates. *)
let partial_shuffle arr k =
  let n = Array.length arr in
  for i = 0 to k - 1 do
    let j = i + Random.int (n - i) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done

(** Deal a full game: 2 hole cards + 2 community cards from the deck.
    When [community] is non-empty, use those as fixed community cards.
    When [community] is empty, deal community cards randomly too. *)
let deal_full_game ~deck ~community =
  match community with
  | _ :: _ :: _ ->
    (* Fixed community: deal 2 hole cards from remaining *)
    let remaining =
      List.filter deck ~f:(fun c ->
        not (List.exists community ~f:(fun cc -> Card.equal c cc)))
    in
    let arr = Array.of_list remaining in
    partial_shuffle arr 2;
    (arr.(0), arr.(1), community)
  | _ ->
    (* Random community: deal 4 cards total *)
    let arr = Array.of_list deck in
    partial_shuffle arr 4;
    (arr.(0), arr.(1), [ arr.(2); arr.(3) ])

(** Compute a hash of leaf values for finer tree fingerprinting.
    Combines the first few leaf values into a single integer. *)
let leaf_hash tree =
  let h = ref 0 in
  let count = ref 0 in
  let _ = Tree.fold_leaves tree ~init:() ~f:(fun () v ->
    match !count < 8 with
    | true ->
      h := !h lxor (Float.iround_nearest_exn (v *. 100.0) lsl (!count * 4));
      Int.incr count
    | false -> ())
  in
  !h

(** Make a cache key from a tree: (size, quantized_ev, leaf_hash).
    Trees must match all three to be treated as structurally identical. *)
let cache_key tree =
  let ev = Tree.ev tree in
  let size = Tree.size tree in
  (size, quantize_ev ev, leaf_hash tree)

(** Find the nearest cluster to a tree, returning (index, distance).
    Uses a distance cache for confirmed hits, and EV pre-filtering for
    remaining comparisons. Returns None when no clusters exist. *)
let find_nearest_cluster ~epsilon ~distance_config ~distance_cache ~cluster_count
    clusters tree =
  match clusters with
  | [] -> None
  | _ ->
    let key = cache_key tree in
    (* Check distance cache for confirmed hits *)
    let cached_valid =
      match Hashtbl.find distance_cache key with
      | Some entry ->
        (* Cache entry is valid only if cluster count hasn't changed *)
        (match entry.cluster_count = cluster_count with
         | true -> Some (entry.cluster_idx, entry.distance)
         | false -> None)
      | None -> None
    in
    (match cached_valid with
     | Some result -> Some result
     | None ->
       (* Full search with EV pre-filtering *)
       let tree_ev = Tree.ev tree in
       let best =
         List.foldi clusters ~init:(0, Float.infinity)
           ~f:(fun i (best_i, best_d) oc ->
             let ev_diff = Float.abs (tree_ev -. oc.rep_ev) in
             match Float.( > ) ev_diff epsilon with
             | true -> (best_i, best_d)
             | false ->
               (match Float.( >= ) ev_diff best_d with
                | true -> (best_i, best_d)
                | false ->
                  let d =
                    Distance.compute_with_config ~config:distance_config
                      tree oc.representative
                  in
                  match Float.( < ) d best_d with
                  | true -> (i, d)
                  | false -> (best_i, best_d)))
       in
       let (best_i, best_d) = best in
       (* Only cache confirmed hits (d < epsilon) *)
       (match Float.( < ) best_d epsilon with
        | true ->
          Hashtbl.set distance_cache ~key
            ~data:{ cluster_idx = best_i
                  ; distance = best_d
                  ; cluster_count
                  }
        | false -> ());
       Some best)

(** Create a new online cluster from a single tree. *)
let create_online_cluster tree =
  let ev = Tree.ev tree in
  { representative = tree
  ; rep_ev = ev
  ; weighted_ev = ev
  ; member_count = 1
  ; diameter = 0.0
  }

(** Record a cache hit: update cluster statistics without modifying the representative.
    This is O(1). *)
let record_hit oc ~tree_ev ~distance =
  let n = Float.of_int oc.member_count in
  let new_count = oc.member_count + 1 in
  let new_wev = (n *. oc.weighted_ev +. tree_ev) /. Float.of_int new_count in
  { oc with
    weighted_ev = new_wev
  ; member_count = new_count
  ; diameter = Float.max oc.diameter distance
  }

(** Attempt to merge close clusters using representative distances.
    Returns the new cluster list and number of merges performed. *)
let merge_close_clusters ~epsilon ~distance_config clusters =
  let arr = Array.of_list clusters in
  let n = Array.length arr in
  let active = Array.create ~len:n true in
  let num_merged = ref 0 in
  let changed = ref true in
  while !changed do
    changed := false;
    let best_dist = ref Float.infinity in
    let best_i = ref (-1) in
    let best_j = ref (-1) in
    for i = 0 to n - 1 do
      match active.(i) with
      | false -> ()
      | true ->
        for j = i + 1 to n - 1 do
          match active.(j) with
          | false -> ()
          | true ->
            let ev_diff = Float.abs (arr.(i).rep_ev -. arr.(j).rep_ev) in
            (match Float.( > ) ev_diff epsilon with
             | true -> ()
             | false ->
               let d =
                 Distance.compute_with_config ~config:distance_config
                   arr.(i).representative arr.(j).representative
               in
               (match Float.( < ) d !best_dist with
                | true ->
                  best_dist := d;
                  best_i := i;
                  best_j := j
                | false -> ()))
        done
    done;
    match Float.( <= ) !best_dist epsilon && !best_i >= 0 with
    | true ->
      let ci = !best_i in
      let cj = !best_j in
      let keep, absorb =
        match arr.(ci).member_count >= arr.(cj).member_count with
        | true -> (ci, cj)
        | false -> (cj, ci)
      in
      let n_keep = Float.of_int arr.(keep).member_count in
      let n_absorb = Float.of_int arr.(absorb).member_count in
      let total = n_keep +. n_absorb in
      let new_wev =
        (n_keep *. arr.(keep).weighted_ev +. n_absorb *. arr.(absorb).weighted_ev)
        /. total
      in
      arr.(keep) <-
        { arr.(keep) with
          weighted_ev = new_wev
        ; member_count = arr.(keep).member_count + arr.(absorb).member_count
        ; diameter = Float.max
            (Float.max arr.(keep).diameter arr.(absorb).diameter)
            !best_dist
        };
      active.(absorb) <- false;
      Int.incr num_merged;
      changed := true
    | false ->
      changed := false
  done;
  let result =
    Array.to_list (Array.filter_mapi active ~f:(fun i is_active ->
      match is_active with
      | true -> Some arr.(i)
      | false -> None))
  in
  (result, !num_merged)

(** Play one game of RI Hold'em and return the generated game tree. *)
let play_game ~config =
  let (p1_card, p2_card, community) =
    deal_full_game ~deck:config.game_config.deck ~community:config.community
  in
  Rhode_island.game_tree_for_deal
    ~config:config.game_config
    ~p1_card ~p2_card
    ~community

(** Create a snapshot of convergence metrics. *)
let make_snapshot ~state ~game_number =
  let total = state.cache_hits + state.cache_misses in
  let cache_hit_rate =
    match total with
    | 0 -> 0.0
    | n -> Float.of_int state.cache_hits /. Float.of_int n
  in
  let num_clusters = List.length state.clusters in
  let compression_ratio =
    match num_clusters with
    | 0 -> 1.0
    | c -> Float.of_int state.total_trees_seen /. Float.of_int c
  in
  let new_cluster_rate =
    match state.recent_games with
    | 0 -> 0.0
    | n -> Float.of_int state.recent_misses /. Float.of_int n
  in
  { game_number
  ; num_clusters
  ; cache_hit_rate
  ; compression_ratio
  ; new_cluster_rate
  }

(** The main online learning loop. Returns final stats and snapshots. *)
let run_loop ~config ~report =
  let state =
    { clusters = []
    ; total_trees_seen = 0
    ; clusters_created = 0
    ; clusters_merged = 0
    ; cache_hits = 0
    ; cache_misses = 0
    ; recent_misses = 0
    ; recent_games = 0
    ; distance_cache = Hashtbl.Poly.create ~size:64 ()
    }
  in
  let snapshots = ref [] in
  for game_num = 1 to config.num_games do
    (* 1. Play a game, generating the game tree *)
    let tree = play_game ~config in
    let tree_ev = Tree.ev tree in
    state.total_trees_seen <- state.total_trees_seen + 1;
    state.recent_games <- state.recent_games + 1;

    let cluster_count = List.length state.clusters in

    (* 2. Find nearest cluster (with cache + EV pre-filter) *)
    let nearest =
      find_nearest_cluster ~epsilon:config.epsilon
        ~distance_config:config.distance_config
        ~distance_cache:state.distance_cache
        ~cluster_count
        state.clusters tree
    in

    (* 3. Decide: cache hit or miss *)
    (match nearest with
     | Some (idx, d) ->
       (match Float.( < ) d config.epsilon with
        | true ->
          (* Cache hit: record statistics only (O(1)) *)
          let oc = List.nth_exn state.clusters idx in
          let updated = record_hit oc ~tree_ev ~distance:d in
          state.clusters <-
            List.mapi state.clusters ~f:(fun i c ->
              match i = idx with
              | true -> updated
              | false -> c);
          state.cache_hits <- state.cache_hits + 1
        | false ->
          (* Cache miss: create new cluster *)
          let new_oc = create_online_cluster tree in
          state.clusters <- state.clusters @ [ new_oc ];
          state.cache_misses <- state.cache_misses + 1;
          state.clusters_created <- state.clusters_created + 1;
          state.recent_misses <- state.recent_misses + 1)
     | None ->
       (* No clusters yet: create first *)
       let new_oc = create_online_cluster tree in
       state.clusters <- [ new_oc ];
       state.cache_misses <- state.cache_misses + 1;
       state.clusters_created <- state.clusters_created + 1;
       state.recent_misses <- state.recent_misses + 1);

    (* 4. Periodically merge close clusters *)
    (match game_num % config.merge_interval = 0 with
     | true ->
       let (merged, n_merged) =
         merge_close_clusters ~epsilon:config.epsilon
           ~distance_config:config.distance_config state.clusters
       in
       state.clusters <- merged;
       state.clusters_merged <- state.clusters_merged + n_merged
     | false -> ());

    (* 5. Periodically report *)
    (match game_num % config.report_interval = 0 with
     | true ->
       let snap = make_snapshot ~state ~game_number:game_num in
       snapshots := snap :: !snapshots;
       (match report with
        | true ->
          printf "Game %4d: %3d clusters, hit_rate=%.1f%%, new_rate=%.1f%%, compress=%.1fx\n%!"
            game_num snap.num_clusters
            (100.0 *. snap.cache_hit_rate)
            (100.0 *. snap.new_cluster_rate)
            snap.compression_ratio
        | false -> ());
       state.recent_misses <- 0;
       state.recent_games <- 0
     | false -> ())
  done;
  let final_stats =
    { games_played = config.num_games
    ; clusters_created = state.clusters_created
    ; clusters_merged = state.clusters_merged
    ; cache_hits = state.cache_hits
    ; cache_misses = state.cache_misses
    ; ev_graph_size = List.length state.clusters
    }
  in
  (final_stats, List.rev !snapshots)

let run ~config =
  let (stats, _snapshots) = run_loop ~config ~report:false in
  stats

let run_exn ~config =
  let n_comm = List.length config.community in
  (match n_comm = 0 || n_comm = 2 with
   | true -> ()
   | false -> failwith "online_learner: community must be empty (random) or exactly 2 cards");
  (match Float.( > ) config.epsilon 0.0 with
   | true -> ()
   | false -> failwith "online_learner: epsilon must be positive");
  (match config.num_games > 0 with
   | true -> ()
   | false -> failwith "online_learner: num_games must be positive");
  run ~config

let run_with_report ~config =
  printf "=== Online Self-Play Learner ===\n%!";
  printf "Deck: %d cards, Community: %s\n%!"
    (List.length config.game_config.deck)
    (String.concat ~sep:" " (List.map config.community ~f:Card.to_string));
  printf "Epsilon: %.1f, Games: %d\n\n%!"
    config.epsilon config.num_games;
  let (stats, snapshots) = run_loop ~config ~report:true in
  printf "\n=== Final Results ===\n%!";
  printf "Games played:     %d\n%!" stats.games_played;
  printf "Clusters created: %d\n%!" stats.clusters_created;
  printf "Clusters merged:  %d\n%!" stats.clusters_merged;
  printf "Final clusters:   %d\n%!" stats.ev_graph_size;
  printf "Cache hits:       %d (%.1f%%)\n%!"
    stats.cache_hits
    (100.0 *. Float.of_int stats.cache_hits
     /. Float.of_int (Int.max 1 (stats.cache_hits + stats.cache_misses)));
  printf "Cache misses:     %d (%.1f%%)\n%!"
    stats.cache_misses
    (100.0 *. Float.of_int stats.cache_misses
     /. Float.of_int (Int.max 1 (stats.cache_hits + stats.cache_misses)));
  printf "Compression:      %.1fx\n%!"
    (Float.of_int stats.games_played
     /. Float.of_int (Int.max 1 stats.ev_graph_size));
  printf "\n=== Convergence Snapshots ===\n%!";
  printf "%8s  %8s  %10s  %10s  %10s\n%!"
    "game" "clusters" "hit_rate" "new_rate" "compress";
  List.iter snapshots ~f:(fun s ->
    printf "%8d  %8d  %9.1f%%  %9.1f%%  %9.1fx\n%!"
      s.game_number s.num_clusters
      (100.0 *. s.cache_hit_rate)
      (100.0 *. s.new_cluster_rate)
      s.compression_ratio)

let run_with_snapshots ~config =
  run_loop ~config ~report:false
