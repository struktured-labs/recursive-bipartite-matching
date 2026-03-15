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
  (** Distance cache: maps (tree_size, tree_ev_quantized) -> (cluster_index, distance).
      Avoids recomputing distance for structurally identical trees. *)
  distance_cache : (int * int, int * float) Hashtbl.t;
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

(** Deal random hole cards for two players from the remaining deck. *)
let deal_cards ~deck ~community =
  let remaining =
    List.filter deck ~f:(fun c ->
      not (List.exists community ~f:(fun cc -> Card.equal c cc)))
  in
  let arr = Array.of_list remaining in
  let n = Array.length arr in
  (* Fisher-Yates shuffle on first 2 positions *)
  let i1 = Random.int n in
  let tmp = arr.(0) in
  arr.(0) <- arr.(i1);
  arr.(i1) <- tmp;
  let i2 = 1 + Random.int (n - 1) in
  let tmp = arr.(1) in
  arr.(1) <- arr.(i2);
  arr.(i2) <- tmp;
  (arr.(0), arr.(1))

(** Make a cache key from a tree: (size, quantized_ev).
    Trees with same size and same EV (to 0.1) are treated as structurally
    identical for caching purposes. This is sound because RI Hold'em trees
    with the same deal structure always have the same size and EV. *)
let cache_key tree =
  let ev = Tree.ev tree in
  let size = Tree.size tree in
  (size, quantize_ev ev)

(** Find the nearest cluster to a tree, returning (index, distance).
    Uses a distance cache for trees with identical structure, and EV
    pre-filtering for remaining comparisons.
    Returns None when no clusters exist. *)
let find_nearest_cluster ~epsilon ~distance_config ~distance_cache clusters tree =
  match clusters with
  | [] -> None
  | _ ->
    let key = cache_key tree in
    (* Check distance cache first *)
    (match Hashtbl.find distance_cache key with
     | Some (cached_idx, cached_dist) ->
       (* Verify the cached cluster still exists at this index *)
       (match cached_idx < List.length clusters with
        | true -> Some (cached_idx, cached_dist)
        | false -> None)  (* cluster was removed by merge; fall through *)
     | None ->
       let tree_ev = Tree.ev tree in
       let best =
         List.foldi clusters ~init:(0, Float.infinity)
           ~f:(fun i (best_i, best_d) oc ->
             let ev_diff = Float.abs (tree_ev -. oc.rep_ev) in
             (* EV pre-filter: skip when EV alone exceeds threshold *)
             match Float.( > ) ev_diff epsilon with
             | true -> (best_i, best_d)
             | false ->
               (* Also skip if EV diff exceeds current best *)
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
       (* Cache the result for future identical trees *)
       Hashtbl.set distance_cache ~key ~data:(best_i, best_d);
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
    This is O(1) and avoids expensive merge + distance recomputation. *)
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
  let (p1_card, p2_card) =
    deal_cards ~deck:config.game_config.deck ~community:config.community
  in
  Rhode_island.game_tree_for_deal
    ~config:config.game_config
    ~p1_card ~p2_card
    ~community:config.community

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

    (* 2. Find nearest cluster (with distance cache + EV pre-filter) *)
    let nearest =
      find_nearest_cluster ~epsilon:config.epsilon
        ~distance_config:config.distance_config
        ~distance_cache:state.distance_cache
        state.clusters tree
    in

    (* 3. Decide: cache hit or miss *)
    (match nearest with
     | Some (idx, d) ->
       (match Float.( < ) d config.epsilon with
        | true ->
          (* Cache hit: record statistics only (O(1), no merge) *)
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
       state.clusters_merged <- state.clusters_merged + n_merged;
       (* Invalidate distance cache after merge (cluster indices changed) *)
       (match n_merged > 0 with
        | true -> Hashtbl.clear state.distance_cache
        | false -> ())
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
  (match List.length config.community = 2 with
   | true -> ()
   | false -> failwith "online_learner: community must have exactly 2 cards (flop + turn)");
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
