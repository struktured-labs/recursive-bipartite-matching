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

(** Mutable state for the online learning loop. *)
type learner_state = {
  mutable clusters : Rhode_island.Node_label.t Ev_graph.cluster list;
  mutable total_trees_seen : int;
  mutable clusters_created : int;
  mutable clusters_merged : int;
  mutable cache_hits : int;
  mutable cache_misses : int;
  mutable recent_misses : int;  (** misses in the current reporting window *)
  mutable recent_games : int;   (** games in the current reporting window *)
}

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

(** Find the nearest cluster to a tree, returning (index, distance).
    Returns None when no clusters exist. *)
let find_nearest_cluster ~distance_config clusters tree =
  match clusters with
  | [] -> None
  | _ ->
    let best =
      List.foldi clusters ~init:(0, Float.infinity)
        ~f:(fun i (best_i, best_d) cluster ->
          let d =
            Distance.compute_with_config ~config:distance_config
              tree cluster.Ev_graph.representative
          in
          match Float.( < ) d best_d with
          | true -> (i, d)
          | false -> (best_i, best_d))
    in
    Some best

(** Create a new cluster from a single tree. *)
let create_cluster ~tree_index tree : Rhode_island.Node_label.t Ev_graph.cluster =
  { representative = tree
  ; members = [ (tree_index, tree) ]
  ; diameter = 0.0
  }

(** Merge a tree into an existing cluster, updating the representative via
    weighted merge. *)
let merge_into_cluster ~distance_config ~tree_index cluster tree
  : Rhode_island.Node_label.t Ev_graph.cluster
  =
  let merge_config =
    { Merge.phantom_policy = Drop; distance_config }
  in
  let n_existing = Float.of_int (List.length cluster.Ev_graph.members) in
  let new_rep =
    Merge.merge_weighted ~config:merge_config
      ~w1:n_existing ~w2:1.0
      cluster.Ev_graph.representative tree
  in
  let d =
    Distance.compute_with_config ~config:distance_config
      tree cluster.Ev_graph.representative
  in
  { Ev_graph.representative = new_rep
  ; members = cluster.members @ [ (tree_index, tree) ]
  ; diameter = Float.max cluster.diameter d
  }

(** Attempt to merge close clusters. Returns the new cluster list and the
    number of merges performed. *)
let merge_close_clusters ~epsilon ~distance_config clusters =
  let arr = Array.of_list clusters in
  let n = Array.length arr in
  let active = Array.create ~len:n true in
  let merge_config =
    { Merge.phantom_policy = Drop; distance_config }
  in
  let num_merged = ref 0 in
  (* Single pass: find pairs within epsilon and merge *)
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
            let d =
              Distance.compute_with_config ~config:distance_config
                arr.(i).Ev_graph.representative
                arr.(j).Ev_graph.representative
            in
            (match Float.( < ) d !best_dist with
             | true ->
               best_dist := d;
               best_i := i;
               best_j := j
             | false -> ())
        done
    done;
    match Float.( <= ) !best_dist epsilon && !best_i >= 0 with
    | true ->
      let ci = !best_i in
      let cj = !best_j in
      let w1 = Float.of_int (List.length arr.(ci).Ev_graph.members) in
      let w2 = Float.of_int (List.length arr.(cj).Ev_graph.members) in
      let new_rep =
        Merge.merge_weighted ~config:merge_config
          ~w1 ~w2
          arr.(ci).Ev_graph.representative
          arr.(cj).Ev_graph.representative
      in
      arr.(ci) <- { Ev_graph.representative = new_rep
                   ; members = arr.(ci).members @ arr.(cj).members
                   ; diameter = Float.max
                       (Float.max arr.(ci).diameter arr.(cj).diameter)
                       !best_dist
                   };
      active.(cj) <- false;
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
    }
  in
  let snapshots = ref [] in
  for game_num = 1 to config.num_games do
    (* 1. Play a game, generating the game tree *)
    let tree = play_game ~config in
    state.total_trees_seen <- state.total_trees_seen + 1;
    state.recent_games <- state.recent_games + 1;

    (* 2. Find nearest cluster *)
    let nearest =
      find_nearest_cluster ~distance_config:config.distance_config
        state.clusters tree
    in

    (* 3. Decide: cache hit or miss *)
    (match nearest with
     | Some (idx, d) ->
       (match Float.( < ) d config.epsilon with
        | true ->
          (* Cache hit: merge into existing cluster *)
          let cluster = List.nth_exn state.clusters idx in
          let updated =
            merge_into_cluster ~distance_config:config.distance_config
              ~tree_index:state.total_trees_seen cluster tree
          in
          state.clusters <-
            List.mapi state.clusters ~f:(fun i c ->
              match i = idx with
              | true -> updated
              | false -> c);
          state.cache_hits <- state.cache_hits + 1
        | false ->
          (* Cache miss: create new cluster *)
          let new_cluster = create_cluster ~tree_index:state.total_trees_seen tree in
          state.clusters <- state.clusters @ [ new_cluster ];
          state.cache_misses <- state.cache_misses + 1;
          state.clusters_created <- state.clusters_created + 1;
          state.recent_misses <- state.recent_misses + 1)
     | None ->
       (* No clusters yet: create first *)
       let new_cluster = create_cluster ~tree_index:state.total_trees_seen tree in
       state.clusters <- [ new_cluster ];
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
  (* Validate config *)
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
      s.compression_ratio);
  let _stats = stats in
  ()

let run_with_snapshots ~config =
  run_loop ~config ~report:false
