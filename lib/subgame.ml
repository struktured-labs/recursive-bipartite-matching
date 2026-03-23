(** Subgame decomposition for No-Limit Hold'em MCCFR training.

    Splits the monolithic training into independent subgames — one per
    (preflop_history, flop_cluster) pair — for 10-50x speedup via
    parallelism and smaller tables. *)

(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type subgame_key = {
  preflop_history : string;
  flop_cluster : int;
}

type subgame_state = {
  key : subgame_key;
  cfr_states : Compact_cfr.cfr_state array;
  mutable iteration_count : int;
}

type decomposed_strategy = {
  preflop_p0 : Compact_cfr.strategy;
  preflop_p1 : Compact_cfr.strategy;
  subgame_dir : string;
  flop_cluster_map : (string, int) Hashtbl.t;
  preflop_histories : string list;
  n_clusters : int;
}

(* ------------------------------------------------------------------ *)
(* Utility: deck shuffling for sampling                                *)
(* ------------------------------------------------------------------ *)

let shuffle_array arr =
  let n = Array.length arr in
  for i = n - 1 downto 1 do
    let j = Random.int (i + 1) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done

(** Sample n distinct cards from deck, avoiding cards in [exclude]. *)
let sample_cards ~(n : int) ~(exclude : Card.t list) : Card.t list =
  let remaining =
    List.filter Card.full_deck ~f:(fun c ->
      not (List.exists exclude ~f:(fun e -> Card.equal c e)))
  in
  let arr = Array.of_list remaining in
  shuffle_array arr;
  List.init (Int.min n (Array.length arr)) ~f:(fun i -> arr.(i))

(* ------------------------------------------------------------------ *)
(* Canonical flop string for hash table keys                           *)
(* ------------------------------------------------------------------ *)

(** Canonical flop string: sort cards by int value, concatenate.
    E.g., "2c3c4c" for the lowest possible flop. *)
let canonical_flop_string (flop : Card.t list) : string =
  let sorted = List.sort flop ~compare:Card.compare in
  String.concat (List.map sorted ~f:Card.to_string)

(* ------------------------------------------------------------------ *)
(* Preflop action replay                                               *)
(* ------------------------------------------------------------------ *)

(** Map a history character back to an action.
    Inverse of Nolimit_holdem.Action.to_history_char. *)
let action_of_char (c : char) : Nolimit_holdem.Action.t =
  match c with
  | 'f' -> Fold
  | 'k' -> Check
  | 'c' -> Call
  | 'q' -> Bet_frac 0.25
  | 't' -> Bet_frac 0.33
  | 'h' -> Bet_frac 0.5
  | 'r' -> Bet_frac 0.75
  | 'p' -> Bet_frac 1.0
  | 'o' -> Bet_frac 1.5
  | 'd' -> Bet_frac 2.0
  | 'a' -> All_in
  | _ -> failwithf "action_of_char: unknown char '%c'" c ()

(** Apply a single action to an nl_state.  Mirrors the logic in
    Compact_cfr.apply_action but implemented here since that function
    is not exported from the mli. *)
let apply_action (_config : Nolimit_holdem.config) (state : Compact_cfr.nl_state)
    (action : Nolimit_holdem.Action.t) : Compact_cfr.nl_state =
  let seat = state.to_act in
  let stack = state.p_stack.(seat) in
  let already_in_round =
    state.p_invested.(seat) - state.round_start_invested.(seat)
  in
  let to_call = Int.min stack (state.current_bet - already_in_round) in
  let pot = Array.fold state.p_invested ~init:0 ~f:( + ) in
  let new_invested = Array.copy state.p_invested in
  let new_stack = Array.copy state.p_stack in
  let other = 1 - seat in
  match action with
  | Fold ->
    { to_act = other
    ; round_idx = state.round_idx
    ; num_raises = state.num_raises
    ; current_bet = state.current_bet
    ; actions_remaining = 0
    ; p_invested = new_invested
    ; p_stack = new_stack
    ; round_start_invested = state.round_start_invested
    }
  | Check ->
    { to_act = other
    ; round_idx = state.round_idx
    ; num_raises = state.num_raises
    ; current_bet = state.current_bet
    ; actions_remaining = state.actions_remaining - 1
    ; p_invested = new_invested
    ; p_stack = new_stack
    ; round_start_invested = state.round_start_invested
    }
  | Call ->
    new_invested.(seat) <- state.p_invested.(seat) + to_call;
    new_stack.(seat) <- stack - to_call;
    { to_act = other
    ; round_idx = state.round_idx
    ; num_raises = state.num_raises
    ; current_bet = state.current_bet
    ; actions_remaining = state.actions_remaining - 1
    ; p_invested = new_invested
    ; p_stack = new_stack
    ; round_start_invested = state.round_start_invested
    }
  | Bet_frac frac ->
    let pot_after_call = pot + to_call in
    let raise_amount =
      Int.max 1 (Float.to_int (Float.of_int pot_after_call *. frac))
    in
    let total_to_put_in = to_call + raise_amount in
    new_invested.(seat) <- state.p_invested.(seat) + total_to_put_in;
    new_stack.(seat) <- stack - total_to_put_in;
    let in_round =
      state.p_invested.(seat) + total_to_put_in
      - state.round_start_invested.(seat)
    in
    { to_act = other
    ; round_idx = state.round_idx
    ; num_raises = state.num_raises + 1
    ; current_bet = in_round
    ; actions_remaining = 1
    ; p_invested = new_invested
    ; p_stack = new_stack
    ; round_start_invested = state.round_start_invested
    }
  | All_in ->
    let all_in_amount = stack in
    new_invested.(seat) <- state.p_invested.(seat) + all_in_amount;
    new_stack.(seat) <- 0;
    let in_round =
      state.p_invested.(seat) + all_in_amount
      - state.round_start_invested.(seat)
    in
    let new_current_bet = Int.max state.current_bet in_round in
    let is_raise = all_in_amount > to_call in
    { to_act = other
    ; round_idx = state.round_idx
    ; num_raises =
        (match is_raise with
         | true -> state.num_raises + 1
         | false -> state.num_raises)
    ; current_bet = new_current_bet
    ; actions_remaining =
        (match is_raise with
         | true -> 1
         | false -> state.actions_remaining - 1)
    ; p_invested = new_invested
    ; p_stack = new_stack
    ; round_start_invested = state.round_start_invested
    }

(** Compute available actions at a decision point.  Mirrors the logic
    in Compact_cfr.available_actions_inline. Returns (action, history_char)
    pairs. *)
let available_actions_at (config : Nolimit_holdem.config)
    ?(action_table : Action_abstraction.t option)
    (state : Compact_cfr.nl_state)
  : (Nolimit_holdem.Action.t * string) list =
  let seat = state.to_act in
  let stack = state.p_stack.(seat) in
  let already_in_round =
    state.p_invested.(seat) - state.round_start_invested.(seat)
  in
  let to_call = Int.min stack (state.current_bet - already_in_round) in
  let facing_bet = to_call > 0 in
  let pot = Array.fold state.p_invested ~init:0 ~f:( + ) in
  let can_raise =
    state.num_raises < config.max_raises_per_round && stack > to_call
  in
  let actions = ref [] in
  (match facing_bet with
   | true ->
     actions := (Nolimit_holdem.Action.Fold, "f") :: !actions
   | false -> ());
  let check_call =
    match facing_bet with
    | true -> (Nolimit_holdem.Action.Call, "c")
    | false -> (Nolimit_holdem.Action.Check, "k")
  in
  actions := check_call :: !actions;
  (match can_raise with
   | true ->
     let pot_after_call = pot + to_call in
     let bet_fracs =
       match action_table with
       | Some tbl ->
         let effective_stack = Int.min state.p_stack.(0) state.p_stack.(1) in
         Action_abstraction.lookup tbl ~big_blind:config.big_blind
           ~street:state.round_idx ~pot ~effective_stack
           ~raise_count:state.num_raises
       | None -> config.bet_fractions
     in
     List.iter bet_fracs ~f:(fun frac ->
       let raise_amount =
         Int.max 1 (Float.to_int (Float.of_int pot_after_call *. frac))
       in
       let total_to_put_in = to_call + raise_amount in
       match total_to_put_in < stack with
       | true ->
         actions :=
           (Nolimit_holdem.Action.Bet_frac frac,
            Nolimit_holdem.Action.to_history_char (Bet_frac frac))
           :: !actions
       | false -> ());
     (match stack > to_call with
      | true ->
        actions := (Nolimit_holdem.Action.All_in, "a") :: !actions
      | false -> ())
   | false -> ());
  List.rev !actions

(* ------------------------------------------------------------------ *)
(* Initial preflop state                                               *)
(* ------------------------------------------------------------------ *)

let initial_preflop_state (config : Nolimit_holdem.config) : Compact_cfr.nl_state =
  let p_invested = [| config.small_blind; config.big_blind |] in
  let p_stack = [|
    config.starting_stack - config.small_blind;
    config.starting_stack - config.big_blind;
  |] in
  let round_start_invested = [| config.small_blind; config.big_blind |] in
  { to_act = 0
  ; round_idx = 0
  ; num_raises = 1
  ; current_bet = config.big_blind
  ; p_invested
  ; p_stack
  ; round_start_invested
  ; actions_remaining = 2
  }

(* ------------------------------------------------------------------ *)
(* Subgame key serialization                                           *)
(* ------------------------------------------------------------------ *)

let subgame_key_to_string (key : subgame_key) : string =
  sprintf "%s|%d" key.preflop_history key.flop_cluster

(* ------------------------------------------------------------------ *)
(* Disk-backed subgame strategy I/O                                    *)
(* ------------------------------------------------------------------ *)

let subgame_filename (key : subgame_key) : string =
  let hist =
    match String.length key.preflop_history with
    | 0 -> "empty"
    | _ -> key.preflop_history
  in
  sprintf "sg_%s_%d.bin" hist key.flop_cluster

(** Convert a strategy hashtable to a marshal-safe list of pairs.
    Core.Hashtbl contains closures that Marshal cannot serialize,
    so we extract the data as a plain list. *)
let strategy_to_alist (strat : Compact_cfr.strategy)
  : (Int64.t * float array) list =
  Hashtbl.fold strat ~init:[] ~f:(fun ~key ~data acc ->
    (key, data) :: acc)

(** Reconstruct a strategy hashtable from a list of pairs. *)
let strategy_of_alist (entries : (Int64.t * float array) list)
  : Compact_cfr.strategy =
  let tbl = Hashtbl.create ~size:(List.length entries) (module Int64) in
  List.iter entries ~f:(fun (key, data) ->
    Hashtbl.set tbl ~key ~data);
  tbl

(** Save one subgame's averaged strategy pair to disk.
    Serializes as lists of [(Int64.t * float array)] to avoid
    marshaling closures inside Core.Hashtbl. *)
let save_subgame_strategy ~(dir : string) ~(key : subgame_key)
    ~(cfr_states : Compact_cfr.cfr_state array) : unit =
  let p0_avg = Compact_cfr.average_strategy cfr_states.(0) in
  let p1_avg = Compact_cfr.average_strategy cfr_states.(1) in
  let p0_list = strategy_to_alist p0_avg in
  let p1_list = strategy_to_alist p1_avg in
  let filename = Filename.concat dir (subgame_filename key) in
  Out_channel.with_file filename ~f:(fun oc ->
    Marshal.to_channel oc (p0_list, p1_list) [])

(** Load one subgame's averaged strategy pair from disk. *)
let load_subgame_strategy ~(dir : string) ~(key : subgame_key)
  : (Compact_cfr.strategy * Compact_cfr.strategy) option =
  let filename = Filename.concat dir (subgame_filename key) in
  match Sys_unix.file_exists filename with
  | `Yes ->
    let (p0_list, p1_list) :
      (Int64.t * float array) list * (Int64.t * float array) list =
      In_channel.with_file filename ~f:(fun ic ->
        Marshal.from_channel ic)
    in
    Some (strategy_of_alist p0_list, strategy_of_alist p1_list)
  | `No | `Unknown -> None

(* ------------------------------------------------------------------ *)
(* Reconstruct state from preflop history                              *)
(* ------------------------------------------------------------------ *)

let reconstruct_state ~(config : Nolimit_holdem.config)
    ~(preflop_history : string) : Compact_cfr.nl_state =
  let state = ref (initial_preflop_state config) in
  String.iter preflop_history ~f:(fun c ->
    let action = action_of_char c in
    state := apply_action config !state action);
  (* Advance to flop: reset round state for round_idx=1 *)
  let s = !state in
  let new_round_start = Array.copy s.p_invested in
  { to_act = 0
  ; round_idx = 1
  ; num_raises = 0
  ; current_bet = 0
  ; p_invested = Array.copy s.p_invested
  ; p_stack = Array.copy s.p_stack
  ; round_start_invested = new_round_start
  ; actions_remaining = 2
  }

(* ------------------------------------------------------------------ *)
(* Enumerate preflop histories                                         *)
(* ------------------------------------------------------------------ *)

let enumerate_preflop_histories ~(config : Nolimit_holdem.config)
    ?(action_table : Action_abstraction.t option)
    () : string list =
  let results = ref [] in
  let rec explore (state : Compact_cfr.nl_state) (history : string) : unit =
    (* If we reached round_idx=1 (or beyond), this history reaches the flop *)
    match state.round_idx >= 1 with
    | true ->
      results := history :: !results
    | false ->
      (* Check if round is over — advance to next round *)
      match state.actions_remaining <= 0 with
      | true ->
        (* Round ended, advance to flop *)
        let new_round_start = Array.copy state.p_invested in
        let new_state : Compact_cfr.nl_state =
          { to_act = 0
          ; round_idx = 1
          ; num_raises = 0
          ; current_bet = 0
          ; p_invested = Array.copy state.p_invested
          ; p_stack = Array.copy state.p_stack
          ; round_start_invested = new_round_start
          ; actions_remaining = 2
          }
        in
        explore new_state history
      | false ->
        let actions = available_actions_at config ?action_table state in
        List.iter actions ~f:(fun (action, hist_char) ->
          match action with
          | Fold ->
            (* Fold ends the hand — don't include in subgame histories *)
            ()
          | _ ->
            let new_state = apply_action config state action in
            let new_history = history ^ hist_char in
            explore new_state new_history)
  in
  explore (initial_preflop_state config) "";
  List.rev !results

(* ------------------------------------------------------------------ *)
(* Flop clustering via RBM distance                                    *)
(* ------------------------------------------------------------------ *)

(** Sample n_flops random 3-card flops from the full deck. *)
let sample_flops ~(n_flops : int) : Card.t list list =
  let deck = Array.of_list Card.full_deck in
  let seen = Hashtbl.Poly.create ~size:n_flops () in
  let flops = ref [] in
  let attempts = ref 0 in
  while List.length !flops < n_flops && !attempts < n_flops * 10 do
    Int.incr attempts;
    shuffle_array deck;
    let flop = List.sort [ deck.(0); deck.(1); deck.(2) ] ~compare:Card.compare in
    let key = canonical_flop_string flop in
    match Hashtbl.mem seen key with
    | true -> ()
    | false ->
      Hashtbl.set seen ~key ~data:();
      flops := flop :: !flops
  done;
  !flops

(** Build a characteristic tree for a flop, averaged over sample hands. *)
let flop_characteristic_tree ~(config : Nolimit_holdem.config)
    ~(flop : Card.t list) ~(n_sample_hands : int)
  : Nolimit_holdem.Node_label.t Tree.t =
  let hands = sample_cards ~n:(n_sample_hands * 2) ~exclude:flop in
  let n_hands = Int.min n_sample_hands (List.length hands / 2) in
  let trees = List.init n_hands ~f:(fun i ->
    let h1 = List.nth_exn hands (i * 2) in
    let h2 = List.nth_exn hands (i * 2 + 1) in
    Nolimit_holdem.showdown_distribution_tree ~max_opponents:5
      ~max_board_samples:2 ~config ~player:0
      ~hole_cards:(h1, h2) ~board_visible:flop ())
  in
  match trees with
  | [] ->
    Tree.leaf ~label:(Nolimit_holdem.Node_label.Chance { description = "empty" })
      ~value:0.0
  | [ t ] -> t
  | first :: rest ->
    (* Average by merging with equal weights *)
    let merge_config = { Merge.phantom_policy = Drop
                       ; distance_config = Distance.default_config } in
    List.fold rest ~init:first ~f:(fun acc t ->
      Merge.merge_weighted ~config:merge_config ~w1:1.0 ~w2:1.0 acc t)

let cluster_flops ~(epsilon : float) ~(n_sample_hands : int)
    ~(config : Nolimit_holdem.config)
    ?(n_flops = 200)
    ?(distance_config = Distance.default_config)
    () : (Card.t list * int) list =
  printf "[subgame] Sampling %d random flops for clustering ...\n%!" n_flops;
  let flops = sample_flops ~n_flops in
  let actual_n = List.length flops in
  printf "[subgame] Building characteristic trees for %d flops (%d sample hands each) ...\n%!"
    actual_n n_sample_hands;
  let trees = List.map flops ~f:(fun flop ->
    flop_characteristic_tree ~config ~flop ~n_sample_hands)
  in
  printf "[subgame] Computing pairwise RBM distances ...\n%!";
  let tree_arr = Array.of_list trees in
  let n = Array.length tree_arr in
  (* Compute pairwise distance matrix *)
  let dist = Array.init n ~f:(fun i ->
    Array.init n ~f:(fun j ->
      match i < j with
      | true ->
        let (d, _depth) =
          Distance.compute_progressive ~config:distance_config
            ~threshold:epsilon tree_arr.(i) tree_arr.(j)
        in
        d
      | false -> 0.0))
  in
  (* Symmetrize *)
  for i = 0 to n - 1 do
    for j = 0 to i - 1 do
      dist.(i).(j) <- dist.(j).(i)
    done
  done;
  (* Agglomerative clustering (single-linkage) *)
  let cluster_of = Array.init n ~f:Fn.id in
  let active = Array.create ~len:n true in
  let continue = ref true in
  while !continue do
    let best_dist = ref Float.infinity in
    let best_ci = ref (-1) in
    let best_cj = ref (-1) in
    for ci = 0 to n - 1 do
      match active.(ci) with
      | false -> ()
      | true ->
        for cj = ci + 1 to n - 1 do
          match active.(cj) with
          | false -> ()
          | true ->
            let d = dist.(ci).(cj) in
            (match Float.( < ) d !best_dist with
             | true -> best_dist := d; best_ci := ci; best_cj := cj
             | false -> ())
        done
    done;
    match Float.( <= ) !best_dist epsilon && !best_ci >= 0 with
    | true ->
      let cj = !best_cj in
      let ci = !best_ci in
      (* Merge cj into ci: update all elements of cj *)
      for k = 0 to n - 1 do
        match cluster_of.(k) = cj with
        | true -> cluster_of.(k) <- ci
        | false -> ()
      done;
      (* Update distances: single-linkage = min *)
      for k = 0 to n - 1 do
        match active.(k) && k <> ci with
        | true ->
          let d_min = Float.min dist.(ci).(k) dist.(cj).(k) in
          dist.(ci).(k) <- d_min;
          dist.(k).(ci) <- d_min
        | false -> ()
      done;
      active.(cj) <- false
    | false ->
      continue := false
  done;
  (* Assign sequential cluster IDs *)
  let cluster_ids = Hashtbl.Poly.create ~size:n () in
  let next_id = ref 0 in
  let flop_arr = Array.of_list flops in
  let result = Array.to_list (Array.mapi flop_arr ~f:(fun i flop ->
    let canonical_ci = cluster_of.(i) in
    let cid =
      match Hashtbl.find cluster_ids canonical_ci with
      | Some id -> id
      | None ->
        let id = !next_id in
        Int.incr next_id;
        Hashtbl.set cluster_ids ~key:canonical_ci ~data:id;
        id
    in
    (flop, cid)))
  in
  let n_clusters = !next_id in
  printf "[subgame] Clustered %d flops into %d clusters (epsilon=%.3f)\n%!"
    actual_n n_clusters epsilon;
  result

(* ------------------------------------------------------------------ *)
(* Flop cluster lookup                                                 *)
(* ------------------------------------------------------------------ *)

let flop_to_cluster ~(cluster_map : (string, int) Hashtbl.t)
    ~(board : Card.t list) : int =
  let flop = List.take board 3 in
  let key = canonical_flop_string flop in
  match Hashtbl.find cluster_map key with
  | Some id -> id
  | None ->
    (* Not found — default to cluster 0.  In production, you would
       find the nearest cluster via RBM distance. *)
    0

(* ------------------------------------------------------------------ *)
(* Strategy lookup (disk-backed)                                       *)
(* ------------------------------------------------------------------ *)

(** Look up action probabilities for a game state.  Preflop decisions
    use the in-memory blueprint; postflop decisions load the relevant
    subgame from disk. *)
let lookup_strategy (ds : decomposed_strategy) ~(player : int)
    ~(round_idx : int) ~(preflop_history : string) ~(board : Card.t list)
    (info_key : Compact_cfr.info_key) : float array option =
  match round_idx with
  | 0 ->
    let strat =
      match player with
      | 0 -> ds.preflop_p0
      | _ -> ds.preflop_p1
    in
    Hashtbl.find strat info_key
  | _ ->
    let cluster = flop_to_cluster ~cluster_map:ds.flop_cluster_map ~board in
    let key = { preflop_history; flop_cluster = cluster } in
    (match load_subgame_strategy ~dir:ds.subgame_dir ~key with
     | None -> None
     | Some (p0, p1) ->
       let strat =
         match player with
         | 0 -> p0
         | _ -> p1
       in
       Hashtbl.find strat info_key)

(* ------------------------------------------------------------------ *)
(* Sample a deal consistent with a flop cluster                        *)
(* ------------------------------------------------------------------ *)

(** Sample a random deal for a subgame: random hole cards + random board
    from the given flop_boards list, completed to 5 cards. *)
let sample_subgame_deal ~(flop_boards : Card.t list list)
  : (Card.t * Card.t) * (Card.t * Card.t) * Card.t list =
  (* Pick a random flop from the cluster *)
  let flop_idx = Random.int (List.length flop_boards) in
  let flop = List.nth_exn flop_boards flop_idx in
  (* Sample hole cards and turn+river avoiding the flop *)
  let remaining =
    List.filter Card.full_deck ~f:(fun c ->
      not (List.exists flop ~f:(fun fc -> Card.equal c fc)))
  in
  let arr = Array.of_list remaining in
  shuffle_array arr;
  (* Need: 2 hole cards for P0, 2 for P1, 2 for turn+river = 6 cards *)
  let p1_cards = (arr.(0), arr.(1)) in
  let p2_cards = (arr.(2), arr.(3)) in
  let board = flop @ [ arr.(4); arr.(5) ] in
  (p1_cards, p2_cards, board)

(* ------------------------------------------------------------------ *)
(* Train a single subgame                                              *)
(* ------------------------------------------------------------------ *)

let train_subgame ~(config : Nolimit_holdem.config)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(key : subgame_key)
    ~(entry_state : Compact_cfr.nl_state)
    ~(flop_boards : Card.t list list)
    ~(iterations : int)
    ~(bucket_method : Compact_cfr.bucket_method)
    ?(action_table : Action_abstraction.t option)
    ?(dcfr = false)
    ?(vr_mccfr = false)
    ()
  : Compact_cfr.cfr_state array =
  ignore action_table;
  let initial_size = 20_000 in
  let cfr_states = [|
    Compact_cfr.create ~size:initial_size ();
    Compact_cfr.create ~size:initial_size ();
  |] in
  (* Set up VR-MCCFR baselines if enabled *)
  (match vr_mccfr with
   | true ->
     Compact_cfr.set_dls_baselines (Some [|
       Compact_cfr.create_baselines ~size:initial_size ();
       Compact_cfr.create_baselines ~size:initial_size ()
     |])
   | false -> ());
  let postflop_states =
    match bucket_method with
    | Rbm_based _ ->
      [| Compact_cfr.create_postflop_state ();
         Compact_cfr.create_postflop_state () |]
    | Equity_based -> [||]
  in
  for iter = 1 to iterations do
    let (p1_cards, p2_cards, board) = sample_subgame_deal ~flop_boards in
    let p1_buckets =
      match bucket_method with
      | Equity_based ->
        Compact_cfr.precompute_buckets_equity ~abstraction ~hole_cards:p1_cards ~board
      | Rbm_based { epsilon; distance_config } ->
        Compact_cfr.precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
          ~postflop:postflop_states.(0) ~hole_cards:p1_cards ~board ~player:0
    in
    let p2_buckets =
      match bucket_method with
      | Equity_based ->
        Compact_cfr.precompute_buckets_equity ~abstraction ~hole_cards:p2_cards ~board
      | Rbm_based { epsilon; distance_config } ->
        Compact_cfr.precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
          ~postflop:postflop_states.(1) ~hole_cards:p2_cards ~board ~player:1
    in
    let traverser = (iter - 1) % 2 in
    (* Start traversal from the entry state (round_idx=1, postflop).
       The history prefix is the preflop_history + "/" to mark the round boundary. *)
    let history = key.preflop_history ^ "/" in
    let state = {
      Compact_cfr.to_act = entry_state.to_act;
      round_idx = entry_state.round_idx;
      num_raises = entry_state.num_raises;
      current_bet = entry_state.current_bet;
      p_invested = Array.copy entry_state.p_invested;
      p_stack = Array.copy entry_state.p_stack;
      round_start_invested = Array.copy entry_state.round_start_invested;
      actions_remaining = entry_state.actions_remaining;
    } in
    (* Update VR iteration counter *)
    (match vr_mccfr with
     | true -> Compact_cfr.set_dls_lcfr_iter iter
     | false -> ());
    let _value = Compact_cfr.mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history ~state ~traverser ~cfr_states in
    (* Apply DCFR discounting *)
    (match dcfr with
     | true ->
       let weights = Compact_cfr.compute_dcfr_weights
         Compact_cfr.default_dcfr_params ~iter in
       Compact_cfr.apply_dcfr_discount cfr_states.(0) weights;
       Compact_cfr.apply_dcfr_discount cfr_states.(1) weights
     | false -> ())
  done;
  (* Clean up VR baselines *)
  (match vr_mccfr with
   | true -> Compact_cfr.set_dls_baselines None
   | false -> ());
  cfr_states

(* ------------------------------------------------------------------ *)
(* Full decomposed training pipeline                                   *)
(* ------------------------------------------------------------------ *)

let train_decomposed ~(config : Nolimit_holdem.config)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(blueprint_iterations : int)
    ~(subgame_iterations : int)
    ~(epsilon : float)
    ~(bucket_method : Compact_cfr.bucket_method)
    ?(num_parallel = Parallel.default_num_domains ())
    ?(action_table : Action_abstraction.t option)
    ?(n_flops = 200)
    ?(n_sample_hands = 5)
    ?(distance_config = Distance.default_config)
    ?(subgame_dir = "subgame_strategies")
    ?(dcfr = false)
    ?(vr_mccfr = false)
    ()
  : decomposed_strategy =
  (* ---- Create output directory ---- *)
  (match Sys_unix.file_exists subgame_dir with
   | `Yes -> ()
   | `No | `Unknown -> Core_unix.mkdir_p subgame_dir);

  (* ---- Phase 1: Train preflop blueprint ---- *)
  printf "[subgame] Phase 1: Training preflop blueprint (%d iterations) ...\n%!"
    blueprint_iterations;
  let (preflop_p0, preflop_p1) =
    Compact_cfr.train_mccfr ~config ~abstraction ~iterations:blueprint_iterations
      ?action_table ~bucket_method ~dcfr ~vr_mccfr ()
  in
  printf "[subgame] Phase 1 complete. P0=%d P1=%d info sets in blueprint.\n%!"
    (Hashtbl.length preflop_p0) (Hashtbl.length preflop_p1);

  (* ---- Phase 2: Cluster flops ---- *)
  printf "[subgame] Phase 2: Clustering flops ...\n%!";
  let flop_clusters = cluster_flops ~epsilon ~n_sample_hands ~config
      ~n_flops ~distance_config () in
  let flop_cluster_map = Hashtbl.create (module String) ~size:(List.length flop_clusters) in
  List.iter flop_clusters ~f:(fun (flop, cid) ->
    let key = canonical_flop_string flop in
    Hashtbl.set flop_cluster_map ~key ~data:cid);
  (* Group flops by cluster *)
  let cluster_to_flops = Hashtbl.Poly.create ~size:64 () in
  List.iter flop_clusters ~f:(fun (flop, cid) ->
    let existing =
      match Hashtbl.find cluster_to_flops cid with
      | Some lst -> lst
      | None -> []
    in
    Hashtbl.set cluster_to_flops ~key:cid ~data:(flop :: existing));
  let n_clusters = Hashtbl.length cluster_to_flops in

  (* ---- Phase 3: Enumerate preflop histories and train subgames ---- *)
  printf "[subgame] Phase 3: Enumerating preflop histories ...\n%!";
  let histories = enumerate_preflop_histories ~config ?action_table () in
  let n_histories = List.length histories in
  printf "[subgame] Found %d preflop histories reaching the flop.\n%!" n_histories;
  let n_subgames = n_histories * n_clusters in
  printf "[subgame] Phase 3: Training %d subgames (%d histories x %d clusters), saving to %s ...\n%!"
    n_subgames n_histories n_clusters subgame_dir;

  (* Build the list of all (key, entry_state, flop_boards) triples *)
  let subgame_specs = ref [] in
  List.iter histories ~f:(fun preflop_history ->
    let entry_state = reconstruct_state ~config ~preflop_history in
    Hashtbl.iteri cluster_to_flops ~f:(fun ~key:cid ~data:flops ->
      let sg_key = { preflop_history; flop_cluster = cid } in
      subgame_specs := (sg_key, entry_state, flops) :: !subgame_specs));
  let specs = Array.of_list (List.rev !subgame_specs) in
  let n_specs = Array.length specs in

  (* Train subgames in parallel — save each to disk and release memory *)
  let completed = Atomic.make 0 in
  let num_workers = Int.max 1 (Int.min num_parallel n_specs) in
  printf "[subgame] Starting %d parallel workers for %d subgames ...\n%!"
    num_workers n_specs;
  let pool = Domainslib.Task.setup_pool ~num_domains:num_workers () in
  Domainslib.Task.run pool (fun () ->
    Domainslib.Task.parallel_for pool ~start:0 ~finish:(n_specs - 1)
      ~body:(fun i ->
        Random.self_init ();
        let (sg_key, entry_state, flop_boards) = specs.(i) in
        let cfr_pair = train_subgame ~config ~abstraction ~key:sg_key
            ~entry_state ~flop_boards ~iterations:subgame_iterations
            ~bucket_method ?action_table ~dcfr ~vr_mccfr () in
        (* Save averaged strategy to disk — each worker writes a unique file *)
        save_subgame_strategy ~dir:subgame_dir ~key:sg_key ~cfr_states:cfr_pair;
        (* cfr_pair goes out of scope here — GC can reclaim it *)
        let done_count = Atomic.fetch_and_add completed 1 + 1 in
        (match done_count % (Int.max 1 (n_specs / 10)) = 0 with
         | true ->
           printf "[subgame] Progress: %d/%d subgames complete (%.0f%%)\n%!"
             done_count n_specs
             (100.0 *. Float.of_int done_count /. Float.of_int n_specs)
         | false -> ())));
  Domainslib.Task.teardown_pool pool;
  printf "[subgame] All %d subgames trained and saved to %s.\n%!" n_specs subgame_dir;

  printf "[subgame] Decomposed strategy: %d preflop info sets, %d subgame files on disk.\n%!"
    (Hashtbl.length preflop_p0 + Hashtbl.length preflop_p1) n_specs;

  { preflop_p0
  ; preflop_p1
  ; subgame_dir
  ; flop_cluster_map
  ; preflop_histories = histories
  ; n_clusters
  }
