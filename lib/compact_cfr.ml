(** Compact-storage Monte Carlo CFR for No-Limit Hold'em.

    Drop-in replacement for {!Cfr_nolimit} that uses monomorphic
    [(string, _) Hashtbl.t] instead of [Hashtbl.Poly.t], cutting
    per-entry overhead by ~3x.  Tables are pre-sized to avoid
    expensive resize cascades.

    All game logic is identical to {!Cfr_nolimit}. *)

(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type info_key = Int64.t

type strategy = (Int64.t, float array) Hashtbl.t

type cfr_entry = {
  data : float array;  (* first n_actions = regrets, second n_actions = strategy *)
  n_actions : int;
}

type cfr_state = {
  entries : (Int64.t, cfr_entry) Hashtbl.t;
}

let create ?(size = 1_000_000) () =
  { entries = Hashtbl.create ~size (module Int64) }

(* ------------------------------------------------------------------ *)
(* Variance-Reduced MCCFR (VR-MCCFR+)                                 *)
(* Schmid et al., "Variance Reduction in Monte Carlo Counterfactual    *)
(* Regret Minimization", AAAI 2019.                                    *)
(* ------------------------------------------------------------------ *)

(** Per-info-set baseline table: maps info_key -> per-action baseline
    estimates (exponential moving averages of observed counterfactual
    values).  Separate from cfr_state to avoid breaking checkpoints. *)
type vr_baselines = (Int64.t, float array) Hashtbl.t

let create_baselines ?(size = 100_000) () : vr_baselines =
  Hashtbl.create ~size (module Int64)

(** Look up (or lazily create) the baseline array for [key]. *)
let get_baseline (baselines : vr_baselines) (key : info_key)
    ~(n_actions : int) : float array =
  Hashtbl.find_or_add baselines key
    ~default:(fun () -> Array.create ~len:n_actions 0.0)

(** Update baseline towards observed counterfactual values using EMA:
    baseline[a] <- (1 - alpha) * baseline[a] + alpha * observed[a] *)
let update_baseline (baseline : float array) (observed : float array)
    ~(alpha : float) : unit =
  Array.iteri baseline ~f:(fun i b ->
    baseline.(i) <- (1.0 -. alpha) *. b +. alpha *. observed.(i))

(** Domain-local baselines — each OCaml 5 domain gets its own per-player
    baseline tables (via [Domain.DLS]).  This is safe for parallel training
    since no two domains share the same mutable baseline arrays.
    [None] disables VR-MCCFR; [Some [| p0_bl; p1_bl |]] enables it. *)
let dls_baselines : vr_baselines array option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

(** Domain-local VR-MCCFR iteration counter (for harmonic alpha). *)
let dls_vr_iter : int Domain.DLS.key =
  Domain.DLS.new_key (fun () -> 0)

(** Convenience accessor: get domain-local baselines. *)
let get_dls_baselines () : vr_baselines array option =
  Domain.DLS.get dls_baselines

(** Convenience accessor: get domain-local VR iteration counter. *)
let get_dls_vr_iter () : int =
  Domain.DLS.get dls_vr_iter

(** Set domain-local baselines for the current domain. *)
let set_dls_baselines (v : vr_baselines array option) : unit =
  Domain.DLS.set dls_baselines v

(** Set domain-local VR iteration counter for the current domain. *)
let set_dls_vr_iter (v : int) : unit =
  Domain.DLS.set dls_vr_iter v

(* ------------------------------------------------------------------ *)
(* Linear CFR (LCFR) — iteration-weighted strategy accumulation        *)
(* "Hyperparameter Schedules for Discounted CFR", arxiv 2404.09097     *)
(* ------------------------------------------------------------------ *)

(** Domain-local LCFR iteration counter.  When > 0, [accumulate_strategy]
    multiplies strategy contributions by the iteration number, giving
    more weight to later (better) strategies.  0 = disabled (uniform
    averaging).  Uses [Domain.DLS] for parallel safety. *)
let dls_lcfr_iter : int Domain.DLS.key =
  Domain.DLS.new_key (fun () -> 0)

(** Convenience accessor: get domain-local LCFR iteration. *)
let get_dls_lcfr_iter () : int =
  Domain.DLS.get dls_lcfr_iter

(** Set domain-local LCFR iteration for the current domain. *)
let set_dls_lcfr_iter (v : int) : unit =
  Domain.DLS.set dls_lcfr_iter v

(* ------------------------------------------------------------------ *)
(* cfr_entry accessors                                                 *)
(* ------------------------------------------------------------------ *)

let entry_regret (entry : cfr_entry) (i : int) : float = entry.data.(i)
let entry_strategy (entry : cfr_entry) (i : int) : float = entry.data.(entry.n_actions + i)
let set_entry_regret (entry : cfr_entry) (i : int) (v : float) : unit = entry.data.(i) <- v
let set_entry_strategy (entry : cfr_entry) (i : int) (v : float) : unit =
  entry.data.(entry.n_actions + i) <- v

let entry_regrets_sub (entry : cfr_entry) : float array =
  Array.sub entry.data ~pos:0 ~len:entry.n_actions

let entry_strategy_sub (entry : cfr_entry) : float array =
  Array.sub entry.data ~pos:entry.n_actions ~len:entry.n_actions

(* ------------------------------------------------------------------ *)
(* Regret matching                                                     *)
(* ------------------------------------------------------------------ *)

let regret_matching (regrets : float array) : float array =
  let n = Array.length regrets in
  let positive = Array.map regrets ~f:(fun r -> Float.max 0.0 r) in
  let total = Array.fold positive ~init:0.0 ~f:( +. ) in
  match Float.( > ) total 0.0 with
  | true  -> Array.map positive ~f:(fun p -> p /. total)
  | false ->
    let uniform = 1.0 /. Float.of_int n in
    Array.create ~len:n uniform

(* ------------------------------------------------------------------ *)
(* Regret-Based Pruning (RBP) — per-action level                      *)
(* ------------------------------------------------------------------ *)

(** [regret_matching_with_pruning regrets ~prune_threshold] is like
    [regret_matching] but also zeroes out actions whose cumulative
    regret is below [prune_threshold].  Returns [(strategy, pruned)]
    where [pruned.(i)] is [true] when action [i] was pruned. *)
let regret_matching_with_pruning (regrets : float array)
    ~(prune_threshold : float) : float array * bool array =
  let n = Array.length regrets in
  let pruned = Array.init n ~f:(fun i ->
    Float.( < ) regrets.(i) prune_threshold) in
  let positive = Array.init n ~f:(fun i ->
    match pruned.(i) with
    | true  -> 0.0
    | false -> Float.max 0.0 regrets.(i)) in
  let total = Array.fold positive ~init:0.0 ~f:( +. ) in
  let strat =
    match Float.( > ) total 0.0 with
    | true  -> Array.map positive ~f:(fun p -> p /. total)
    | false ->
      (* Count unpruned actions for uniform fallback *)
      let n_active = Array.count pruned ~f:(fun p ->
        match p with true -> false | false -> true) in
      match n_active > 0 with
      | true ->
        let u = 1.0 /. Float.of_int n_active in
        Array.init n ~f:(fun i ->
          match pruned.(i) with true -> 0.0 | false -> u)
      | false ->
        (* All pruned — fall back to full uniform *)
        let uniform = 1.0 /. Float.of_int n in
        Array.create ~len:n uniform
  in
  (strat, pruned)

(* ------------------------------------------------------------------ *)
(* Discounted CFR (DCFR) — Brown & Sandholm 2019                      *)
(* ------------------------------------------------------------------ *)

(** DCFR hyperparameters: [alpha] and [beta] control regret discount
    for positive/negative regrets; [gamma] controls strategy-sum
    discount. *)
type dcfr_params = {
  alpha : float;
  beta  : float;
  gamma : float;
}

let default_dcfr_params = { alpha = 1.5; beta = 0.0; gamma = 2.0 }

(** DCFR hyperparameter schedule selector.
    [Fixed params]: constant hyperparameters (original DCFR).
    [Linear_weighted]: LCFR -- weight each iteration's strategy
      contribution by its iteration number, so later (better)
      strategies dominate the average.  2-5x faster convergence.
    [Adaptive { base }]: placeholder for future learned schedules. *)
type dcfr_schedule =
  | Fixed of dcfr_params
  | Linear_weighted
  | Adaptive of { base : dcfr_params }

(** [dcfr_weights params ~iter] computes the three discount factors
    for iteration [iter]:
    - [pos_regret_weight]: t^alpha / (t^alpha + 1)
    - [neg_regret_weight]: t^beta / (t^beta + 1)
    - [strategy_weight]:   (t / (t + 1))^gamma *)
type dcfr_weights = {
  pos_regret_weight : float;
  neg_regret_weight : float;
  strategy_weight   : float;
}

let compute_dcfr_weights (params : dcfr_params) ~(iter : int) : dcfr_weights =
  let t = Float.of_int iter in
  let t_alpha = Float.( ** ) t params.alpha in
  let t_beta  = Float.( ** ) t params.beta in
  let pos_regret_weight = t_alpha /. (t_alpha +. 1.0) in
  let neg_regret_weight = t_beta  /. (t_beta  +. 1.0) in
  let strategy_weight   = Float.( ** ) (t /. (t +. 1.0)) params.gamma in
  { pos_regret_weight; neg_regret_weight; strategy_weight }

(** [apply_dcfr_discount state weights] multiplies all existing regret
    and strategy sums in [state] by the DCFR discount factors.
    Positive regrets are scaled by [pos_regret_weight], negative by
    [neg_regret_weight], and strategy sums by [strategy_weight]. *)
let apply_dcfr_discount (state : cfr_state) (w : dcfr_weights) : unit =
  Hashtbl.iter state.entries ~f:(fun entry ->
    let n = entry.n_actions in
    for i = 0 to n - 1 do
      let r = entry_regret entry i in
      let scaled =
        match Float.( >= ) r 0.0 with
        | true  -> r *. w.pos_regret_weight
        | false -> r *. w.neg_regret_weight
      in
      set_entry_regret entry i scaled
    done;
    for i = 0 to n - 1 do
      set_entry_strategy entry i (entry_strategy entry i *. w.strategy_weight)
    done)

let find_or_add_entry (state : cfr_state) (key : info_key) ~(num_actions : int) : cfr_entry =
  Hashtbl.find_or_add state.entries key
    ~default:(fun () ->
      { data = Array.create ~len:(2 * num_actions) 0.0
      ; n_actions = num_actions
      })

let get_strategy (state : cfr_state) (key : info_key) ~(num_actions : int) : float array =
  let entry = find_or_add_entry state key ~num_actions in
  regret_matching (entry_regrets_sub entry)

(** [get_strategy_pruned state key ~num_actions ~prune_threshold] is
    like [get_strategy] but also applies regret-based pruning at the
    per-action level.  Returns [(strategy, pruned)] where [pruned.(i)]
    indicates action [i] should be skipped during traversal. *)
let get_strategy_pruned (state : cfr_state) (key : info_key)
    ~(num_actions : int) ~(prune_threshold : float)
  : float array * bool array =
  let entry = find_or_add_entry state key ~num_actions in
  regret_matching_with_pruning (entry_regrets_sub entry) ~prune_threshold

let accumulate_strategy (state : cfr_state) (key : info_key)
    (strat : float array) (weight : float) =
  let num_actions = Array.length strat in
  let entry = find_or_add_entry state key ~num_actions in
  (* LCFR: when enabled (dls_lcfr_iter > 0), multiply the strategy
     contribution by the iteration number.  Later iterations produce
     better strategies, so they should dominate the average. *)
  let iter_weight =
    match get_dls_lcfr_iter () > 0 with
    | true  -> Float.of_int (get_dls_lcfr_iter ())
    | false -> 1.0
  in
  Array.iteri strat ~f:(fun i p ->
    set_entry_strategy entry i
      (entry_strategy entry i +. weight *. p *. iter_weight))

let average_strategy (state : cfr_state) : strategy =
  let result = Hashtbl.create ~size:(Hashtbl.length state.entries) (module Int64) in
  Hashtbl.iteri state.entries ~f:(fun ~key ~data:entry ->
    let n = entry.n_actions in
    let total = ref 0.0 in
    for i = 0 to n - 1 do
      total := !total +. entry_strategy entry i
    done;
    let avg =
      match Float.( > ) !total 0.0 with
      | true  ->
        Array.init n ~f:(fun i -> entry_strategy entry i /. !total)
      | false ->
        Array.create ~len:n (1.0 /. Float.of_int n)
    in
    Hashtbl.set result ~key ~data:avg);
  result

(* ------------------------------------------------------------------ *)
(* Random deal sampling                                                *)
(* ------------------------------------------------------------------ *)

let shuffle_array arr =
  let n = Array.length arr in
  for i = n - 1 downto 1 do
    let j = Random.int (i + 1) in
    let tmp = arr.(i) in
    arr.(i) <- arr.(j);
    arr.(j) <- tmp
  done

let sample_deal () =
  let deck = Array.of_list Card.full_deck in
  shuffle_array deck;
  let p1 = (deck.(0), deck.(1)) in
  let p2 = (deck.(2), deck.(3)) in
  let board = [ deck.(4); deck.(5); deck.(6); deck.(7); deck.(8) ] in
  (p1, p2, board)

(* ------------------------------------------------------------------ *)
(* Bucket-based info-set key (FNV-1a int64 hash)                       *)
(* ------------------------------------------------------------------ *)

(** FNV-1a constants for 64-bit hashing. *)
let fnv_offset_basis = 0xcbf29ce484222325L
let fnv_prime        = 0x100000001b3L

(** [fnv1a_mix_byte h b] folds a single byte into FNV-1a state. *)
let fnv1a_mix_byte (h : int64) (b : int) : int64 =
  Int64.( * ) (Int64.( lxor ) h (Int64.of_int b)) fnv_prime

(** [fnv1a_mix_int h n] folds a native int into the hash state
    by feeding its 8 bytes (little-endian). *)
let fnv1a_mix_int (h : int64) (n : int) : int64 =
  let h = fnv1a_mix_byte h (n land 0xFF) in
  let h = fnv1a_mix_byte h ((n lsr 8) land 0xFF) in
  let h = fnv1a_mix_byte h ((n lsr 16) land 0xFF) in
  let h = fnv1a_mix_byte h ((n lsr 24) land 0xFF) in
  let h = fnv1a_mix_byte h ((n lsr 32) land 0xFF) in
  let h = fnv1a_mix_byte h ((n lsr 40) land 0xFF) in
  let h = fnv1a_mix_byte h ((n lsr 48) land 0xFF) in
  fnv1a_mix_byte h ((n lsr 56) land 0xFF)

(** [fnv1a_mix_string h s] folds every byte of [s] into the hash state. *)
let fnv1a_mix_string (h : int64) (s : string) : int64 =
  let len = String.length s in
  let h = ref h in
  for i = 0 to len - 1 do
    h := fnv1a_mix_byte !h (Char.to_int (String.unsafe_get s i))
  done;
  !h

(** [make_info_key ~buckets ~round_idx ~history] hashes bucket assignments,
    round index, and action history into a single [Int64.t] via FNV-1a.
    Zero allocation --- no intermediate strings on the hot path. *)
let make_info_key ~(buckets : int array) ~(round_idx : int) ~(history : string) : info_key =
  let last = Int.min round_idx 3 in
  let h = ref fnv_offset_basis in
  for i = 0 to last do
    h := fnv1a_mix_int !h buckets.(i)
  done;
  (* Separator byte between structural components *)
  let h = fnv1a_mix_byte !h 0xFF in
  let h = fnv1a_mix_int h round_idx in
  let h = fnv1a_mix_byte h 0xFE in
  fnv1a_mix_string h history

(* -- String-based key for debugging --------------------------------- *)

(** Write the decimal digits of non-negative [n] into [buf] starting at [pos].
    Returns the new position after the last digit written. *)
let write_int_digits (buf : Bytes.t) (pos : int) (n : int) : int =
  match n with
  | 0 ->
    Bytes.set buf pos '0';
    pos + 1
  | _ ->
    let nd = ref 0 in
    let v = ref n in
    while !v > 0 do
      Int.incr nd;
      v := !v / 10
    done;
    let end_pos = pos + !nd in
    v := n;
    for i = end_pos - 1 downto pos do
      Bytes.set buf i (Char.of_int_exn (Char.to_int '0' + (!v % 10)));
      v := !v / 10
    done;
    end_pos

(** [make_info_key_string] produces the old human-readable string key
    (e.g. ["B34:29:78:3|cc/kk/kh"]) for debugging and diagnostics. *)
let make_info_key_string ~(buckets : int array) ~(round_idx : int) ~(history : string) : string =
  let history_len = String.length history in
  let buf = Bytes.create (40 + history_len) in
  Bytes.set buf 0 'B';
  let pos = ref 1 in
  let last = Int.min round_idx 3 in
  for i = 0 to last do
    (match i with
     | 0 -> ()
     | _ ->
       Bytes.set buf !pos ':';
       pos := !pos + 1);
    pos := write_int_digits buf !pos buckets.(i)
  done;
  Bytes.set buf !pos '|';
  pos := !pos + 1;
  Stdlib.Bytes.blit_string history 0 buf !pos history_len;
  pos := !pos + history_len;
  Stdlib.Bytes.sub_string buf 0 !pos

(* ------------------------------------------------------------------ *)
(* Bucket computation per street (equity-based)                        *)
(* ------------------------------------------------------------------ *)

let hand_score (hole_cards : Card.t * Card.t) (board_visible : Card.t list) : float =
  let (h1, h2) = hole_cards in
  let cards = [ h1; h2 ] @ board_visible in
  let n = List.length cards in
  let (rank, tiebreakers) =
    match n with
    | 7 -> Hand_eval7.evaluate7 cards
    | 6 ->
      let arr = Array.of_list cards in
      let best = ref (Hand_eval5.Hand_rank.High_card, [ 0 ]) in
      for skip = 0 to 5 do
        let c = Array.filteri arr ~f:(fun i _ -> i <> skip) in
        let (r, tb) = Hand_eval5.evaluate c.(0) c.(1) c.(2) c.(3) c.(4) in
        let cmp_rank = Int.compare
            (Hand_eval5.Hand_rank.to_int r)
            (Hand_eval5.Hand_rank.to_int (fst !best)) in
        match cmp_rank > 0 with
        | true -> best := (r, tb)
        | false ->
          match cmp_rank = 0 with
          | true ->
            let cmp_tb = List.compare Int.compare tb (snd !best) in
            (match cmp_tb > 0 with
             | true -> best := (r, tb)
             | false -> ())
          | false -> ()
      done;
      !best
    | 5 ->
      let arr = Array.of_list cards in
      Hand_eval5.evaluate arr.(0) arr.(1) arr.(2) arr.(3) arr.(4)
    | _ ->
      (Hand_eval5.Hand_rank.High_card, [ 0 ])
  in
  let rank_score = Float.of_int (Hand_eval5.Hand_rank.to_int rank) /. 9.0 in
  let tb_score =
    match tiebreakers with
    | [] -> 0.0
    | first :: _ -> Float.of_int first /. 150.0
  in
  Float.min 0.999 (rank_score +. tb_score *. 0.1)

let compute_bucket_equity
    ~(abstraction : Abstraction.abstraction_partial)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(round_idx : int)
  : int =
  match round_idx with
  | 0 ->
    Abstraction.get_bucket abstraction ~hole_cards
  | _ ->
    let board_visible =
      match round_idx with
      | 1 -> List.take board 3
      | 2 -> List.take board 4
      | _ -> board
    in
    let score = hand_score hole_cards board_visible in
    let n = abstraction.n_buckets in
    Int.min (n - 1) (Float.to_int (score *. Float.of_int n))

let precompute_buckets_equity
    ~(abstraction : Abstraction.abstraction_partial)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
  : int array =
  Array.init 4 ~f:(fun round_idx ->
    compute_bucket_equity ~abstraction ~hole_cards ~board ~round_idx)

(* ------------------------------------------------------------------ *)
(* RBM-based postflop bucketing                                        *)
(* ------------------------------------------------------------------ *)

type bucket_method =
  | Equity_based
  | Rbm_based of { epsilon : float; distance_config : Distance.config }

type postflop_cluster = {
  representative : Nolimit_holdem.Node_label.t Tree.t;
  rep_ev : float;
  mutable member_count : int;
}

type postflop_state = {
  clusters : (int, postflop_cluster list ref) Hashtbl.t;
}

let create_postflop_state () =
  { clusters = Hashtbl.Poly.create ~size:4 () }

let find_nearest_postflop_cluster ~epsilon ~distance_config clusters tree =
  match clusters with
  | [] -> None
  | _ ->
    let tree_ev = Tree.ev tree in
    let best =
      List.foldi clusters ~init:(0, Float.infinity)
        ~f:(fun i (best_i, best_d) oc ->
          let ev_diff = Float.abs (tree_ev -. oc.rep_ev) in
          match Float.( > ) ev_diff epsilon with
          | true -> (best_i, best_d)
          | false ->
            match Float.( >= ) ev_diff best_d with
            | true -> (best_i, best_d)
            | false ->
              let (d, _depth) =
                Distance.compute_progressive ~config:distance_config
                  ~threshold:epsilon tree oc.representative
              in
              match Float.( < ) d best_d with
              | true -> (i, d)
              | false -> (best_i, best_d))
    in
    Some best

let compute_bucket_rbm_postflop
    ~(config : Nolimit_holdem.config)
    ~(epsilon : float)
    ~(distance_config : Distance.config)
    ~(postflop : postflop_state)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(round_idx : int)
    ~(player : int)
  : int =
  let board_visible =
    match round_idx with
    | 1 -> List.take board 3
    | 2 -> List.take board 4
    | _ -> board
  in
  let is_tree =
    Nolimit_holdem.showdown_distribution_tree ~max_opponents:5
      ~max_board_samples:2 ~config
      ~player ~hole_cards ~board_visible ()
  in
  let clusters_ref =
    match Hashtbl.find postflop.clusters round_idx with
    | Some r -> r
    | None ->
      let r = ref [] in
      Hashtbl.set postflop.clusters ~key:round_idx ~data:r;
      r
  in
  let clusters = !clusters_ref in
  let nearest =
    find_nearest_postflop_cluster ~epsilon ~distance_config clusters is_tree
  in
  match nearest with
  | Some (idx, d) ->
    (match Float.( < ) d epsilon with
     | true ->
       let oc = List.nth_exn clusters idx in
       oc.member_count <- oc.member_count + 1;
       idx
     | false ->
       let new_cluster =
         { representative = is_tree
         ; rep_ev = Tree.ev is_tree
         ; member_count = 1
         }
       in
       clusters_ref := clusters @ [ new_cluster ];
       List.length clusters)
  | None ->
    let new_cluster =
      { representative = is_tree
      ; rep_ev = Tree.ev is_tree
      ; member_count = 1
      }
    in
    clusters_ref := [ new_cluster ];
    0

let compute_bucket_rbm
    ~(abstraction : Abstraction.abstraction_partial)
    ~(config : Nolimit_holdem.config)
    ~(epsilon : float)
    ~(distance_config : Distance.config)
    ~(postflop : postflop_state)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(round_idx : int)
    ~(player : int)
  : int =
  match round_idx with
  | 0 ->
    Abstraction.get_bucket abstraction ~hole_cards
  | _ ->
    compute_bucket_rbm_postflop ~config ~epsilon ~distance_config
      ~postflop ~hole_cards ~board ~round_idx ~player

let precompute_buckets_rbm
    ~(abstraction : Abstraction.abstraction_partial)
    ~(config : Nolimit_holdem.config)
    ~(epsilon : float)
    ~(distance_config : Distance.config)
    ~(postflop : postflop_state)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(player : int)
  : int array =
  Array.init 4 ~f:(fun round_idx ->
    compute_bucket_rbm ~abstraction ~config ~epsilon ~distance_config
      ~postflop ~hole_cards ~board ~round_idx ~player)

(* ------------------------------------------------------------------ *)
(* NL-specific round state                                             *)
(* ------------------------------------------------------------------ *)

type nl_state = {
  to_act : int;
  round_idx : int;
  num_raises : int;
  current_bet : int;
  p_invested : int array;
  p_stack : int array;
  round_start_invested : int array;
  actions_remaining : int;
}

(* ------------------------------------------------------------------ *)
(* Action generation for inline traversal                              *)
(* ------------------------------------------------------------------ *)

let available_actions_inline
    ?(action_table : Action_abstraction.t option)
    (config : Nolimit_holdem.config) (state : nl_state)
  : (Nolimit_holdem.Action.t * string) list =
  let seat = state.to_act in
  let stack = state.p_stack.(seat) in
  let already_in_round =
    state.p_invested.(seat) - state.round_start_invested.(seat)
  in
  let to_call = Int.min stack (state.current_bet - already_in_round) in
  let facing_bet = to_call > 0 in
  let pot =
    Array.fold state.p_invested ~init:0 ~f:( + )
  in
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
     (* Use action table for context-dependent bet sizes, or config default *)
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

let apply_action (_config : Nolimit_holdem.config) (state : nl_state)
    (action : Nolimit_holdem.Action.t) : nl_state =
  let seat = state.to_act in
  let stack = state.p_stack.(seat) in
  let already_in_round =
    state.p_invested.(seat) - state.round_start_invested.(seat)
  in
  let to_call = Int.min stack (state.current_bet - already_in_round) in
  let pot = Array.fold state.p_invested ~init:0 ~f:( + ) in
  let new_invested = Array.copy state.p_invested in
  let new_stack = Array.copy state.p_stack in
  let new_round_start = Array.copy state.round_start_invested in
  let _ = new_round_start in
  let other = 1 - seat in
  match action with
  | Fold ->
    { state with
      to_act = other
    ; actions_remaining = 0
    ; p_invested = new_invested
    ; p_stack = new_stack
    ; round_start_invested = state.round_start_invested
    }
  | Check ->
    { state with
      to_act = other
    ; actions_remaining = state.actions_remaining - 1
    ; p_invested = new_invested
    ; p_stack = new_stack
    ; round_start_invested = state.round_start_invested
    }
  | Call ->
    new_invested.(seat) <- state.p_invested.(seat) + to_call;
    new_stack.(seat) <- stack - to_call;
    { state with
      to_act = other
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
    { state with
      to_act = other
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
    { state with
      to_act = other
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

(* ------------------------------------------------------------------ *)
(* Showdown payoff                                                     *)
(* ------------------------------------------------------------------ *)

let showdown_payoff ~(p1_cards : Card.t * Card.t) ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list) ~(p_invested : int array) ~(traverser : int) : float =
  let (p1a, p1b) = p1_cards in
  let (p2a, p2b) = p2_cards in
  let hand1 = [ p1a; p1b ] @ board in
  let hand2 = [ p2a; p2b ] @ board in
  let cmp = Hand_eval7.compare_hands7 hand1 hand2 in
  let pot = p_invested.(0) + p_invested.(1) in
  let p0_value =
    match cmp > 0 with
    | true  -> Float.of_int (pot - p_invested.(0))
    | false ->
      match cmp < 0 with
      | true  -> Float.of_int (- p_invested.(0))
      | false -> 0.0
  in
  match traverser with
  | 0 -> p0_value
  | _ -> Float.neg p0_value

(* ------------------------------------------------------------------ *)
(* Inline betting tree traversal                                       *)
(* ------------------------------------------------------------------ *)

(* Module-level action table — set before training, used by available_actions_inline *)
let global_action_table : Action_abstraction.t option ref = ref None

(* Module-level prune threshold — set before training, read by mccfr_traverse.
   [None] disables per-action pruning; [Some c] prunes actions with
   cumulative regret below [c]. *)
let global_prune_threshold : float option ref = ref None

let rec mccfr_traverse
    ~(config : Nolimit_holdem.config)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(p1_buckets : int array)
    ~(p2_buckets : int array)
    ~(history : string)
    ~(state : nl_state)
    ~(traverser : int)
    ~(cfr_states : cfr_state array)
  : float =
  let player = state.to_act in
  let buckets =
    match player with
    | 0 -> p1_buckets
    | _ -> p2_buckets
  in
  let key = make_info_key ~buckets ~round_idx:state.round_idx ~history in
  let actions = available_actions_inline ?action_table:!global_action_table config state in
  let num_actions = List.length actions in

  match num_actions with
  | 0 ->
    advance_to_next_round ~config ~p1_cards ~p2_cards ~board
      ~p1_buckets ~p2_buckets ~history ~state ~traverser ~cfr_states
  | _ ->
    let cfr_st = cfr_states.(player) in
    (* When the current player is the traverser and RBP is enabled,
       use per-action pruning to skip subtrees for deeply negative
       regret actions. *)
    let strat, pruned =
      match player = traverser, !global_prune_threshold with
      | true, Some prune_threshold ->
        get_strategy_pruned cfr_st key ~num_actions ~prune_threshold
      | _, _ ->
        (get_strategy cfr_st key ~num_actions, Array.create ~len:num_actions false)
    in
    let action_arr = Array.of_list actions in

    let action_payoff i =
      let (action, hist_char) = action_arr.(i) in
      let new_history = history ^ hist_char in
      let new_state = apply_action config state action in
      match action with
      | Fold ->
        let winner = 1 - player in
        let pot = new_state.p_invested.(0) + new_state.p_invested.(1) in
        let p0_value =
          match winner = 0 with
          | true -> Float.of_int (pot - new_state.p_invested.(0))
          | false -> Float.of_int (- new_state.p_invested.(0))
        in
        (match traverser with
         | 0 -> p0_value
         | _ -> Float.neg p0_value)
      | Call ->
        (match new_state.actions_remaining <= 0 with
         | true ->
           advance_to_next_round ~config ~p1_cards ~p2_cards ~board
             ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
             ~traverser ~cfr_states
         | false ->
           mccfr_traverse ~config ~p1_cards ~p2_cards ~board
             ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
             ~traverser ~cfr_states)
      | Check ->
        (match new_state.actions_remaining <= 0 with
         | true ->
           advance_to_next_round ~config ~p1_cards ~p2_cards ~board
             ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
             ~traverser ~cfr_states
         | false ->
           mccfr_traverse ~config ~p1_cards ~p2_cards ~board
             ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
             ~traverser ~cfr_states)
      | Bet_frac _ | All_in ->
        (match new_state.actions_remaining <= 0 with
         | true ->
           advance_to_next_round ~config ~p1_cards ~p2_cards ~board
             ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
             ~traverser ~cfr_states
         | false ->
           mccfr_traverse ~config ~p1_cards ~p2_cards ~board
             ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
             ~traverser ~cfr_states)
    in

    handle_decision ~player ~traverser ~cfr_st ~key ~strat ~num_actions
      ~action_payoffs:action_payoff ~pruned

and handle_decision ~(player : int) ~(traverser : int) ~(cfr_st : cfr_state)
    ~(key : info_key) ~(strat : float array) ~(num_actions : int)
    ~(action_payoffs : int -> float) ~(pruned : bool array) : float =
  match player = traverser with
  | true ->
    accumulate_strategy cfr_st key strat 1.0;
    (* For pruned actions, skip the subtree traversal entirely and
       use 0.0 as a placeholder value.  The action's probability is
       already 0 in [strat], so the node_value calculation is
       unaffected.  We still update regrets for pruned actions (their
       regret delta is [0.0 - node_value]), allowing them to recover
       if the node value shifts. *)
    let action_values = Array.init num_actions ~f:(fun i ->
      match pruned.(i) with
      | true  -> 0.0
      | false -> action_payoffs i) in
    let node_value = Array.foldi action_values ~init:0.0 ~f:(fun i acc v ->
      acc +. strat.(i) *. v)
    in
    let entry = find_or_add_entry cfr_st key ~num_actions in
    (* VR-MCCFR+: when baselines are available, subtract per-action
       baselines from counterfactual values before computing regret
       updates.  This is mathematically equivalent (unbiased) to
       standard MCCFR but dramatically reduces variance.
       See Schmid et al., AAAI 2019. *)
    (match get_dls_baselines () with
     | Some bl_arr ->
       let bl = get_baseline bl_arr.(player) key ~n_actions:num_actions in
       (* Compute variance-reduced node value:
          vr_node_value = sum_j(strat[j] * (cfv[j] - baseline[j])) *)
       let vr_node_value = ref 0.0 in
       for i = 0 to num_actions - 1 do
         vr_node_value := !vr_node_value
           +. strat.(i) *. (action_values.(i) -. bl.(i))
       done;
       (* Variance-reduced regret update:
          regret[a] += (cfv[a] - baseline[a]) - vr_node_value *)
       Array.iteri action_values ~f:(fun i v ->
         match pruned.(i) with
         | true  -> ()
         | false ->
           let vr_regret = (v -. bl.(i)) -. !vr_node_value in
           set_entry_regret entry i (entry_regret entry i +. vr_regret));
       (* Update baselines towards observed cfvs using harmonic EMA:
          alpha = 1 / (iter + 1) *)
       let alpha = 1.0 /. Float.of_int (get_dls_vr_iter () + 1) in
       update_baseline bl action_values ~alpha
     | None ->
       (* Standard MCCFR regret update *)
       Array.iteri action_values ~f:(fun i v ->
         match pruned.(i) with
         | true  -> ()
         | false ->
           set_entry_regret entry i (entry_regret entry i +. (v -. node_value))));
    (* MCCFR+: floor negative regrets to zero *)
    for i = 0 to num_actions - 1 do
      match Float.( < ) (entry_regret entry i) 0.0 with
      | true  -> set_entry_regret entry i 0.0
      | false -> ()
    done;
    node_value
  | false ->
    accumulate_strategy cfr_st key strat 1.0;
    let r = Random.float 1.0 in
    let sampled = ref 0 in
    let cumul = ref strat.(0) in
    while !sampled < num_actions - 1 && Float.( < ) !cumul r do
      sampled := !sampled + 1;
      cumul := !cumul +. strat.(!sampled)
    done;
    action_payoffs !sampled

and advance_to_next_round
    ~(config : Nolimit_holdem.config)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(p1_buckets : int array)
    ~(p2_buckets : int array)
    ~(history : string)
    ~(state : nl_state)
    ~(traverser : int)
    ~(cfr_states : cfr_state array)
  : float =
  let next_round = state.round_idx + 1 in
  let someone_all_in =
    state.p_stack.(0) = 0 || state.p_stack.(1) = 0
  in
  match next_round >= 4 || someone_all_in with
  | true ->
    showdown_payoff ~p1_cards ~p2_cards ~board
      ~p_invested:state.p_invested ~traverser
  | false ->
    let new_round_start = Array.copy state.p_invested in
    let new_state = {
      to_act = 0;
      round_idx = next_round;
      num_raises = 0;
      current_bet = 0;
      p_invested = Array.copy state.p_invested;
      p_stack = Array.copy state.p_stack;
      round_start_invested = new_round_start;
      actions_remaining = 2;
    } in
    let new_history = history ^ "/" in
    mccfr_traverse ~config ~p1_cards ~p2_cards ~board
      ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
      ~traverser ~cfr_states

(* ------------------------------------------------------------------ *)
(* Top-level training loop                                             *)
(* ------------------------------------------------------------------ *)

(* ------------------------------------------------------------------ *)
(* Checkpoint serialization                                            *)
(* ------------------------------------------------------------------ *)

(** Magic header for the v2 chunked binary format (int64 keys). *)
let chunked_magic = "RBMCFR02"

(** Magic header for the v1 chunked binary format (string keys). *)
let chunked_magic_v1 = "RBMCFR01"

(* -- Marshal format (int64 keys) ------------------------------------ *)

let load_checkpoint_marshal ~(filename : string) : cfr_state array =
  let ic = In_channel.create filename in
  let (p0_regret, p0_strat, p1_regret, p1_strat) :
    (int64 * float array) list * (int64 * float array) list *
    (int64 * float array) list * (int64 * float array) list =
    Marshal.from_channel ic
  in
  In_channel.close ic;
  let merge_to_entries regret_list strat_list =
    let tbl = Hashtbl.create (module Int64) ~size:(List.length regret_list) in
    List.iter regret_list ~f:(fun (k, regrets) ->
      let n = Array.length regrets in
      let strategy =
        match List.Assoc.find strat_list ~equal:Int64.equal k with
        | Some s -> s
        | None -> Array.create ~len:n 0.0
      in
      let combined = Array.create ~len:(2 * n) 0.0 in
      Array.blit ~src:regrets ~dst:combined ~src_pos:0 ~dst_pos:0 ~len:n;
      Array.blit ~src:strategy ~dst:combined ~src_pos:0 ~dst_pos:n ~len:n;
      Hashtbl.set tbl ~key:k ~data:{ data = combined; n_actions = n });
    (* Add strategy-only entries not in regret_list *)
    List.iter strat_list ~f:(fun (k, strategy) ->
      match Hashtbl.mem tbl k with
      | true -> ()
      | false ->
        let n = Array.length strategy in
        let combined = Array.create ~len:(2 * n) 0.0 in
        Array.blit ~src:strategy ~dst:combined ~src_pos:0 ~dst_pos:n ~len:n;
        Hashtbl.set tbl ~key:k ~data:{ data = combined; n_actions = n });
    tbl
  in
  [| { entries = merge_to_entries p0_regret p0_strat }
   ; { entries = merge_to_entries p1_regret p1_strat }
  |]

let save_checkpoint_marshal ~(filename : string) (cfr_states : cfr_state array) : unit =
  let entries_to_alists entries =
    Hashtbl.fold entries ~init:([], []) ~f:(fun ~key ~data (racc, sacc) ->
      ((key, entry_regrets_sub data) :: racc, (key, entry_strategy_sub data) :: sacc))
  in
  let (p0_regret, p0_strat) = entries_to_alists cfr_states.(0).entries in
  let (p1_regret, p1_strat) = entries_to_alists cfr_states.(1).entries in
  let data = (p0_regret, p0_strat, p1_regret, p1_strat) in
  let oc = Out_channel.create filename in
  Marshal.to_channel oc data [];
  Out_channel.close oc

(* -- Chunked binary format v2 (streaming, int64 keys) --------------- *)

(** Binary layout (v2):
    {[
      magic      : 8 bytes  "RBMCFR02"
      version    : 4 bytes  (int32-le, currently 2)
      n_tables   : 4 bytes  (int32-le, always 4)
      -- for each table:
        n_entries  : 8 bytes (int64-le)
        -- for each entry:
          key        : 8 bytes (int64-le, FNV-1a hash)
          arr_len    : 4 bytes (int32-le)
          arr_floats : arr_len * 8 bytes (float64, native endian)
    ]} *)

let write_int32_le (oc : Out_channel.t) (v : int) : unit =
  let buf = Bytes.create 4 in
  Bytes.set buf 0 (Char.of_int_exn (v land 0xFF));
  Bytes.set buf 1 (Char.of_int_exn ((v lsr 8) land 0xFF));
  Bytes.set buf 2 (Char.of_int_exn ((v lsr 16) land 0xFF));
  Bytes.set buf 3 (Char.of_int_exn ((v lsr 24) land 0xFF));
  Out_channel.output oc ~buf ~pos:0 ~len:4

let write_int64_le (oc : Out_channel.t) (v : int) : unit =
  let buf = Bytes.create 8 in
  for i = 0 to 7 do
    Bytes.set buf i (Char.of_int_exn ((v lsr (i * 8)) land 0xFF))
  done;
  Out_channel.output oc ~buf ~pos:0 ~len:8

let write_int64_le_raw (oc : Out_channel.t) (v : int64) : unit =
  let buf = Bytes.create 8 in
  for i = 0 to 7 do
    Bytes.set buf i
      (Char.of_int_exn
         (Int64.to_int_exn
            (Int64.( land )
               (Int64.shift_right_logical v (i * 8))
               0xFFL)))
  done;
  Out_channel.output oc ~buf ~pos:0 ~len:8

(** Read exactly [len] bytes from [ic] into [buf] starting at [pos].
    Loops to handle partial reads from In_channel.input. *)
let read_exact (ic : In_channel.t) ~(buf : Bytes.t) ~(pos : int) ~(len : int) : bool =
  let remaining = ref len in
  let offset = ref pos in
  while !remaining > 0 do
    let n = In_channel.input ic ~buf ~pos:!offset ~len:!remaining in
    match n = 0 with
    | true -> remaining := -1  (* EOF *)
    | false ->
      offset := !offset + n;
      remaining := !remaining - n
  done;
  !remaining = 0

let read_int32_le (ic : In_channel.t) : int =
  let buf = Bytes.create 4 in
  (match read_exact ic ~buf ~pos:0 ~len:4 with
   | true ->
     Char.to_int (Bytes.get buf 0)
     lor (Char.to_int (Bytes.get buf 1) lsl 8)
     lor (Char.to_int (Bytes.get buf 2) lsl 16)
     lor (Char.to_int (Bytes.get buf 3) lsl 24)
   | false -> failwith "read_int32_le: unexpected EOF")

let read_int64_le (ic : In_channel.t) : int =
  let buf = Bytes.create 8 in
  (match read_exact ic ~buf ~pos:0 ~len:8 with
   | true ->
     let v = ref 0 in
     for i = 0 to 7 do
       v := !v lor (Char.to_int (Bytes.get buf i) lsl (i * 8))
     done;
     !v
   | false -> failwith "read_int64_le: unexpected EOF")

let read_int64_le_raw (ic : In_channel.t) : int64 =
  let buf = Bytes.create 8 in
  (match read_exact ic ~buf ~pos:0 ~len:8 with
   | true ->
     let v = ref 0L in
     for i = 0 to 7 do
       v := Int64.( lor ) !v
         (Int64.shift_left
            (Int64.of_int_exn (Char.to_int (Bytes.get buf i)))
            (i * 8))
     done;
     !v
   | false -> failwith "read_int64_le_raw: unexpected EOF")

let write_float_array_chunked (oc : Out_channel.t) (data : float array) : unit =
  let arr_len = Array.length data in
  write_int32_le oc arr_len;
  let float_buf = Bytes.create (arr_len * 8) in
  Array.iteri data ~f:(fun i f ->
    let bits = Int64.bits_of_float f in
    for b = 0 to 7 do
      Bytes.set float_buf ((i * 8) + b)
        (Char.of_int_exn (Int64.to_int_exn (Int64.( land ) (Int64.shift_right_logical bits (b * 8)) 0xFFL)))
    done);
  Out_channel.output oc ~buf:float_buf ~pos:0 ~len:(arr_len * 8)

let read_float_array_chunked (ic : In_channel.t) : float array =
  let arr_len = read_int32_le ic in
  let float_buf = Bytes.create (arr_len * 8) in
  (match read_exact ic ~buf:float_buf ~pos:0 ~len:(arr_len * 8) with
   | true -> ()
   | false -> failwith "read_float_array_chunked: unexpected EOF reading floats");
  Array.init arr_len ~f:(fun i ->
    let bits = ref 0L in
    for b = 0 to 7 do
      bits := Int64.( lor ) !bits
        (Int64.shift_left (Int64.of_int_exn (Char.to_int (Bytes.get float_buf ((i * 8) + b)))) (b * 8))
    done;
    Int64.float_of_bits !bits)

(** Write one "table" from entries by extracting a field with [project]. *)
let write_entries_as_table (oc : Out_channel.t) (entries : (Int64.t, cfr_entry) Hashtbl.t)
    ~(project : cfr_entry -> float array) : unit =
  let n_entries = Hashtbl.length entries in
  write_int64_le oc n_entries;
  Hashtbl.iteri entries ~f:(fun ~key ~data ->
    write_int64_le_raw oc key;
    write_float_array_chunked oc (project data))

(** Read one "table" back into a [(Int64.t, float array) list] of (key, array) pairs. *)
let read_table_chunked (ic : In_channel.t) : (int64 * float array) list =
  let n_entries = read_int64_le ic in
  let acc = ref [] in
  for _ = 1 to n_entries do
    let key = read_int64_le_raw ic in
    let data = read_float_array_chunked ic in
    acc := (key, data) :: !acc
  done;
  !acc

let save_checkpoint_chunked ~(filename : string) (cfr_states : cfr_state array) : unit =
  let oc = Out_channel.create filename in
  Out_channel.output_string oc chunked_magic;
  write_int32_le oc 2;
  write_int32_le oc 4;
  write_entries_as_table oc cfr_states.(0).entries ~project:entry_regrets_sub;
  write_entries_as_table oc cfr_states.(0).entries ~project:entry_strategy_sub;
  write_entries_as_table oc cfr_states.(1).entries ~project:entry_regrets_sub;
  write_entries_as_table oc cfr_states.(1).entries ~project:entry_strategy_sub;
  Out_channel.flush oc;
  Out_channel.close oc

let load_checkpoint_chunked ~(filename : string) : cfr_state array =
  let ic = In_channel.create filename in
  let magic_buf = Bytes.create 8 in
  (match read_exact ic ~buf:magic_buf ~pos:0 ~len:8 with
   | true -> ()
   | false -> failwithf "load_checkpoint_chunked: unexpected EOF reading magic in %s" filename ());
  let magic_str = Bytes.to_string magic_buf in
  (match String.equal magic_str chunked_magic with
   | true -> ()
   | false ->
     (match String.equal magic_str chunked_magic_v1 with
      | true ->
        failwithf "load_checkpoint_chunked: %s uses v1 string-key format \
                    (RBMCFR01) which is incompatible with int64 keys. \
                    Re-train or convert offline." filename ()
      | false ->
        failwithf "load_checkpoint_chunked: bad magic in %s" filename ()));
  let version = read_int32_le ic in
  (match version = 2 with
   | true -> ()
   | false -> failwithf "load_checkpoint_chunked: unsupported version %d" version ());
  let n_tables = read_int32_le ic in
  (match n_tables = 4 with
   | true -> ()
   | false -> failwithf "load_checkpoint_chunked: expected 4 tables, got %d" n_tables ());
  let p0_regret = read_table_chunked ic in
  let p0_strat = read_table_chunked ic in
  let p1_regret = read_table_chunked ic in
  let p1_strat = read_table_chunked ic in
  In_channel.close ic;
  let merge_tables regret_list strat_list =
    let tbl = Hashtbl.create (module Int64) ~size:(List.length regret_list) in
    List.iter regret_list ~f:(fun (k, regrets) ->
      let n = Array.length regrets in
      let strategy =
        match List.Assoc.find strat_list ~equal:Int64.equal k with
        | Some s -> s
        | None -> Array.create ~len:n 0.0
      in
      let combined = Array.create ~len:(2 * n) 0.0 in
      Array.blit ~src:regrets ~dst:combined ~src_pos:0 ~dst_pos:0 ~len:n;
      Array.blit ~src:strategy ~dst:combined ~src_pos:0 ~dst_pos:n ~len:n;
      Hashtbl.set tbl ~key:k ~data:{ data = combined; n_actions = n });
    List.iter strat_list ~f:(fun (k, strategy) ->
      match Hashtbl.mem tbl k with
      | true -> ()
      | false ->
        let n = Array.length strategy in
        let combined = Array.create ~len:(2 * n) 0.0 in
        Array.blit ~src:strategy ~dst:combined ~src_pos:0 ~dst_pos:n ~len:n;
        Hashtbl.set tbl ~key:k ~data:{ data = combined; n_actions = n });
    tbl
  in
  [| { entries = merge_tables p0_regret p0_strat }
   ; { entries = merge_tables p1_regret p1_strat }
  |]

(* -- Auto-detecting load -------------------------------------------- *)

let is_chunked_format ~(filename : string) : bool =
  let ic = In_channel.create filename in
  let buf = Bytes.create 8 in
  let n = In_channel.input ic ~buf ~pos:0 ~len:8 in
  In_channel.close ic;
  let s = Bytes.to_string buf in
  n = 8 && (String.equal s chunked_magic || String.equal s chunked_magic_v1)

(** [load_checkpoint] auto-detects the format (chunked vs Marshal). *)
let load_checkpoint ~(filename : string) : cfr_state array =
  match is_chunked_format ~filename with
  | true  -> load_checkpoint_chunked ~filename
  | false -> load_checkpoint_marshal ~filename

(** [save_checkpoint] uses the chunked format by default. *)
let save_checkpoint ~(filename : string) (cfr_states : cfr_state array) : unit =
  save_checkpoint_chunked ~filename cfr_states

(* ------------------------------------------------------------------ *)
(* Inline regret pruning (avoids dependency cycle with Cfr_pruning)    *)
(* ------------------------------------------------------------------ *)

(** Remove entries where all regrets are strictly negative. *)
let prune_dominated_entries (state : cfr_state) : int =
  let keys_to_remove =
    Hashtbl.fold state.entries ~init:[] ~f:(fun ~key ~data acc ->
      let dominated = ref true in
      (match data.n_actions = 0 with
       | true -> dominated := false
       | false ->
         for i = 0 to data.n_actions - 1 do
           match Float.( >= ) (entry_regret data i) 0.0 with
           | true -> dominated := false
           | false -> ()
         done);
      match !dominated with
      | true -> key :: acc
      | false -> acc)
  in
  List.iter keys_to_remove ~f:(fun key ->
    Hashtbl.remove state.entries key);
  List.length keys_to_remove

let prune_periodically_inline ~(every : int) ~(iter : int) (state : cfr_state) : unit =
  match iter % every = 0 with
  | true ->
    let pruned = prune_dominated_entries state in
    (match pruned > 0 with
     | true ->
       printf "CFR pruning (iter %d): removed %d dominated info sets\n%!" iter pruned
     | false -> ())
  | false -> ()

let train_mccfr ~(config : Nolimit_holdem.config)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(iterations : int)
    ?(report_every = 10_000)
    ?(initial_size = 1_000_000)
    ?(checkpoint_every = 0)
    ?(checkpoint_prefix = "checkpoint")
    ?(resume_from : string option)
    ?(bucket_method : bucket_method = Equity_based)
    ?(action_table : Action_abstraction.t option)
    ?(dcfr = false)
    ?(prune_threshold = -300_000_000.0)
    ?(vr_mccfr = false)
    ?(lcfr = false)
    ()
  : strategy * strategy =
  global_action_table := action_table;
  global_prune_threshold :=
    (match Float.is_finite prune_threshold with
     | true  -> Some prune_threshold
     | false -> None);
  (* LCFR: initialise domain-local iteration counter *)
  (match lcfr with
   | true  ->
     set_dls_lcfr_iter 0;
     printf "  [LCFR] enabled (linear iteration-weighted strategy averaging)\n%!"
   | false ->
     set_dls_lcfr_iter 0);
  (* VR-MCCFR+: create per-player baseline tables when enabled *)
  (match vr_mccfr with
   | true ->
     set_dls_baselines
       (Some [| create_baselines ~size:initial_size ()
              ; create_baselines ~size:initial_size ()
              |]);
     set_dls_vr_iter 0;
     printf "  [VR-MCCFR+] enabled (harmonic baseline schedule)\n%!"
   | false ->
     set_dls_baselines None);
  (match action_table with
   | Some tbl ->
     printf "  [Action table] %d contexts, %.1f avg bet sizes\n%!"
       (Action_abstraction.num_contexts tbl)
       (Action_abstraction.avg_actions_per_context tbl)
   | None -> ());
  (match dcfr with
   | true ->
     let p = default_dcfr_params in
     printf "  [DCFR] enabled (alpha=%.1f, beta=%.1f, gamma=%.1f)\n%!"
       p.alpha p.beta p.gamma
   | false -> ());
  (match !global_prune_threshold with
   | Some c ->
     printf "  [RBP] per-action pruning threshold=%.0f\n%!" c
   | None -> ());
  let cfr_states =
    match resume_from with
    | Some filename ->
      printf "  [Resume] Loading checkpoint from %s ...\n%!" filename;
      let states = load_checkpoint ~filename in
      printf "  [Resume] Loaded P0=%d P1=%d info sets. Continuing training.\n%!"
        (Hashtbl.length states.(0).entries)
        (Hashtbl.length states.(1).entries);
      states
    | None ->
      [| create ~size:initial_size (); create ~size:initial_size () |]
  in
  let postflop_states =
    match bucket_method with
    | Rbm_based _ -> [| create_postflop_state (); create_postflop_state () |]
    | Equity_based -> [||]
  in
  (match bucket_method with
   | Rbm_based { epsilon; _ } ->
     printf "  [Bucketing] RBM-based (epsilon=%.3f)\n%!" epsilon
   | Equity_based ->
     printf "  [Bucketing] Equity-based\n%!");
  let util_sum = ref 0.0 in
  for iter = 1 to iterations do
    let (p1_cards, p2_cards, board) = sample_deal () in
    let p1_buckets =
      match bucket_method with
      | Equity_based ->
        precompute_buckets_equity ~abstraction ~hole_cards:p1_cards ~board
      | Rbm_based { epsilon; distance_config } ->
        precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
          ~postflop:postflop_states.(0) ~hole_cards:p1_cards ~board ~player:0
    in
    let p2_buckets =
      match bucket_method with
      | Equity_based ->
        precompute_buckets_equity ~abstraction ~hole_cards:p2_cards ~board
      | Rbm_based { epsilon; distance_config } ->
        precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
          ~postflop:postflop_states.(1) ~hole_cards:p2_cards ~board ~player:1
    in
    let traverser = (iter - 1) % 2 in
    let p_invested = [| config.small_blind; config.big_blind |] in
    let p_stack = [|
      config.starting_stack - config.small_blind;
      config.starting_stack - config.big_blind;
    |] in
    let round_start_invested = [| config.small_blind; config.big_blind |] in
    let state = {
      to_act = 0;
      round_idx = 0;
      num_raises = 1;
      current_bet = config.big_blind;
      p_invested;
      p_stack;
      round_start_invested;
      actions_remaining = 2;
    } in
    (* LCFR: set iteration weight before traversal so accumulate_strategy
       picks it up during this iteration's tree walk *)
    (match lcfr with
     | true  -> set_dls_lcfr_iter iter
     | false -> ());
    let value = mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:"" ~state ~traverser ~cfr_states in
    util_sum := !util_sum +. value;
    (* VR-MCCFR+: advance the iteration counter for harmonic alpha *)
    (match vr_mccfr with
     | true  -> set_dls_vr_iter iter
     | false -> ());
    (* DCFR: discount regrets and strategy sums after each iteration *)
    (match dcfr with
     | true ->
       let w = compute_dcfr_weights default_dcfr_params ~iter in
       apply_dcfr_discount cfr_states.(0) w;
       apply_dcfr_discount cfr_states.(1) w
     | false -> ());
    (match iter % report_every = 0 with
     | true ->
       let avg_util = !util_sum /. Float.of_int iter in
       let n_infosets_0 = Hashtbl.length cfr_states.(0).entries in
       let n_infosets_1 = Hashtbl.length cfr_states.(1).entries in
       printf "  [Compact-MCCFR-NL] iter %d/%d  avg_util=%.4f  infosets=(%d, %d)\n%!"
         iter iterations avg_util n_infosets_0 n_infosets_1
     | false -> ());
    (match checkpoint_every > 0 && iter % checkpoint_every = 0 with
     | true ->
       let filename = sprintf "%s_%d.dat" checkpoint_prefix iter in
       printf "  [Checkpoint] Saving %s ...\n%!" filename;
       save_checkpoint ~filename cfr_states;
       printf "  [Checkpoint] Done.\n%!"
     | false -> ());
    (* Prune dominated info sets every 500K iterations *)
    prune_periodically_inline ~every:500_000 ~iter cfr_states.(0);
    prune_periodically_inline ~every:500_000 ~iter cfr_states.(1)
  done;
  global_prune_threshold := None;
  set_dls_baselines None;
  set_dls_lcfr_iter 0;
  let p0_avg = average_strategy cfr_states.(0) in
  let p1_avg = average_strategy cfr_states.(1) in
  (p0_avg, p1_avg)

(* ------------------------------------------------------------------ *)
(* Parallel MCCFR training                                            *)
(* ------------------------------------------------------------------ *)

(** Copy a cfr_state by deep-copying each hash table entry. *)
let copy_cfr_state (src : cfr_state) : cfr_state =
  let tbl2 = Hashtbl.create (module Int64) ~size:(Hashtbl.length src.entries) in
  Hashtbl.iteri src.entries ~f:(fun ~key ~data ->
    Hashtbl.set tbl2 ~key
      ~data:{ data = Array.copy data.data
            ; n_actions = data.n_actions
            });
  { entries = tbl2 }

(** Merge [src] into [dst] by summing regret and strategy arrays
    element-wise.  Mutates [dst] in place. *)
let merge_cfr_state_into ~(dst : cfr_state) ~(src : cfr_state) : unit =
  Hashtbl.iteri src.entries ~f:(fun ~key ~data:src_entry ->
    match Hashtbl.find dst.entries key with
    | Some dst_entry ->
      (* Sum the entire combined data array (regrets + strategy) *)
      Array.iteri src_entry.data ~f:(fun i v ->
        dst_entry.data.(i) <- dst_entry.data.(i) +. v)
    | None ->
      Hashtbl.set dst.entries ~key
        ~data:{ data = Array.copy src_entry.data
              ; n_actions = src_entry.n_actions
              })

let train_mccfr_parallel ~(config : Nolimit_holdem.config)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(iterations : int)
    ?(report_every = 10_000)
    ?(initial_size = 1_000_000)
    ?(checkpoint_every = 0)
    ?(checkpoint_prefix = "checkpoint")
    ?(resume_from : string option)
    ?(num_domains = Parallel.default_num_domains ())
    ?(bucket_method : bucket_method = Equity_based)
    ?(action_table : Action_abstraction.t option)
    ?(dcfr = false)
    ?(prune_threshold = -300_000_000.0)
    ?(vr_mccfr = false)
    ?(lcfr = false)
    ()
  : strategy * strategy =
  global_action_table := action_table;
  global_prune_threshold :=
    (match Float.is_finite prune_threshold with
     | true  -> Some prune_threshold
     | false -> None);
  let num_workers = Int.max 1 num_domains in
  printf "  [Parallel-MCCFR] Starting %d domains, %d iterations total\n%!"
    num_workers iterations;
  (match lcfr with
   | true  -> printf "  [LCFR] enabled (linear iteration-weighted strategy averaging)\n%!"
   | false -> ());
  (match vr_mccfr with
   | true  -> printf "  [VR-MCCFR+] enabled (harmonic baseline schedule, per-domain)\n%!"
   | false -> ());
  (match dcfr with
   | true ->
     let p = default_dcfr_params in
     printf "  [DCFR] enabled (alpha=%.1f, beta=%.1f, gamma=%.1f)\n%!"
       p.alpha p.beta p.gamma
   | false -> ());
  (match !global_prune_threshold with
   | Some c ->
     printf "  [RBP] per-action pruning threshold=%.0f\n%!" c
   | None -> ());
  (* Load or create the base state *)
  let base_states =
    match resume_from with
    | Some filename ->
      printf "  [Resume] Loading checkpoint from %s ...\n%!" filename;
      let states = load_checkpoint ~filename in
      printf "  [Resume] Loaded P0=%d P1=%d info sets.\n%!"
        (Hashtbl.length states.(0).entries)
        (Hashtbl.length states.(1).entries);
      states
    | None ->
      [| create ~size:initial_size (); create ~size:initial_size () |]
  in
  (* Divide iterations among workers *)
  let iters_per_worker = iterations / num_workers in
  let remainder = iterations % num_workers in
  let worker_iters = Array.init num_workers ~f:(fun i ->
    match i < remainder with
    | true  -> iters_per_worker + 1
    | false -> iters_per_worker)
  in
  (* Each worker starts with EMPTY state — do NOT copy the resume
     checkpoint to every worker (that would use N x 90GB+ of RAM).
     Workers accumulate fresh regrets independently, then we merge
     all worker states + the base state at the end. This is correct
     because MCCFR regret/strategy sums are additive. *)
  let worker_states = Array.init num_workers ~f:(fun _i ->
    [| create ~size:initial_size ()
     ; create ~size:initial_size ()
    |])
  in
  let worker_utils = Array.create ~len:num_workers 0.0 in
  (* Atomic counter for progress reporting *)
  let global_iter = Atomic.make 0 in
  let pool = Domainslib.Task.setup_pool ~num_domains:num_workers () in
  Domainslib.Task.run pool (fun () ->
    Domainslib.Task.parallel_for pool ~start:0 ~finish:(num_workers - 1)
      ~body:(fun worker_id ->
        (* Seed each worker's domain-local RNG independently *)
        Random.self_init ();
        let my_states = worker_states.(worker_id) in
        let my_iters = worker_iters.(worker_id) in
        (* LCFR: initialise domain-local iteration counter *)
        set_dls_lcfr_iter 0;
        (* VR-MCCFR+: each domain gets its own baseline tables via DLS *)
        (match vr_mccfr with
         | true ->
           set_dls_baselines
             (Some [| create_baselines ~size:initial_size ()
                    ; create_baselines ~size:initial_size ()
                    |]);
           set_dls_vr_iter 0
         | false ->
           set_dls_baselines None);
        (* Each worker gets its own postflop cluster state (mutable, not shared) *)
        let my_postflop =
          match bucket_method with
          | Rbm_based _ -> [| create_postflop_state (); create_postflop_state () |]
          | Equity_based -> [||]
        in
        let local_util_sum = ref 0.0 in
        for iter = 1 to my_iters do
          let (p1_cards, p2_cards, board) = sample_deal () in
          let p1_buckets =
            match bucket_method with
            | Equity_based ->
              precompute_buckets_equity ~abstraction ~hole_cards:p1_cards ~board
            | Rbm_based { epsilon; distance_config } ->
              precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
                ~postflop:my_postflop.(0) ~hole_cards:p1_cards ~board ~player:0
          in
          let p2_buckets =
            match bucket_method with
            | Equity_based ->
              precompute_buckets_equity ~abstraction ~hole_cards:p2_cards ~board
            | Rbm_based { epsilon; distance_config } ->
              precompute_buckets_rbm ~abstraction ~config ~epsilon ~distance_config
                ~postflop:my_postflop.(1) ~hole_cards:p2_cards ~board ~player:1
          in
          let traverser = (iter - 1) % 2 in
          let p_invested = [| config.small_blind; config.big_blind |] in
          let p_stack = [|
            config.starting_stack - config.small_blind;
            config.starting_stack - config.big_blind;
          |] in
          let round_start_invested = [| config.small_blind; config.big_blind |] in
          let state = {
            to_act = 0;
            round_idx = 0;
            num_raises = 1;
            current_bet = config.big_blind;
            p_invested;
            p_stack;
            round_start_invested;
            actions_remaining = 2;
          } in
          (* LCFR: set iteration weight before traversal *)
          (match lcfr with
           | true  -> set_dls_lcfr_iter iter
           | false -> ());
          let value = mccfr_traverse ~config ~p1_cards ~p2_cards ~board
              ~p1_buckets ~p2_buckets ~history:"" ~state ~traverser
              ~cfr_states:my_states in
          local_util_sum := !local_util_sum +. value;
          (* VR-MCCFR+: advance the domain-local iteration counter *)
          (match vr_mccfr with
           | true  -> set_dls_vr_iter iter
           | false -> ());
          (* DCFR: discount regrets and strategy sums after each iteration *)
          (match dcfr with
           | true ->
             let w = compute_dcfr_weights default_dcfr_params ~iter in
             apply_dcfr_discount my_states.(0) w;
             apply_dcfr_discount my_states.(1) w
           | false -> ());
          let total = Atomic.fetch_and_add global_iter 1 + 1 in
          (match total % report_every = 0 with
           | true ->
             let n0 = Hashtbl.length my_states.(0).entries in
             let n1 = Hashtbl.length my_states.(1).entries in
             printf "  [Parallel-MCCFR] ~%d/%d iters (worker %d: %d/%d)  infosets=(%d,%d)\n%!"
               total iterations worker_id iter my_iters n0 n1
           | false -> ());
          (* Prune dominated info sets every 500K iterations *)
          prune_periodically_inline ~every:500_000 ~iter my_states.(0);
          prune_periodically_inline ~every:500_000 ~iter my_states.(1)
        done;
        (* Clean up domain-local state *)
        set_dls_baselines None;
        set_dls_lcfr_iter 0;
        worker_utils.(worker_id) <- !local_util_sum));
  Domainslib.Task.teardown_pool pool;
  global_prune_threshold := None;
  (* Merge all worker states into worker 0, then add the base (resume) state *)
  printf "  [Parallel-MCCFR] Merging %d worker states + base state ...\n%!" num_workers;
  let merged = worker_states.(0) in
  for w = 1 to num_workers - 1 do
    merge_cfr_state_into ~dst:merged.(0) ~src:worker_states.(w).(0);
    merge_cfr_state_into ~dst:merged.(1) ~src:worker_states.(w).(1)
  done;
  (* Add accumulated regrets/strategies from the resume checkpoint *)
  merge_cfr_state_into ~dst:merged.(0) ~src:base_states.(0);
  merge_cfr_state_into ~dst:merged.(1) ~src:base_states.(1);
  let total_util = Array.fold worker_utils ~init:0.0 ~f:( +. ) in
  let avg_util = total_util /. Float.of_int iterations in
  printf "  [Parallel-MCCFR] Done. avg_util=%.4f  infosets=(%d, %d)\n%!"
    avg_util
    (Hashtbl.length merged.(0).entries)
    (Hashtbl.length merged.(1).entries);
  (* Optional final checkpoint *)
  (match checkpoint_every > 0 with
   | true ->
     let filename = sprintf "%s_final_%d.dat" checkpoint_prefix iterations in
     printf "  [Checkpoint] Saving final %s ...\n%!" filename;
     save_checkpoint ~filename merged;
     printf "  [Checkpoint] Done.\n%!"
   | false -> ());
  let p0_avg = average_strategy merged.(0) in
  let p1_avg = average_strategy merged.(1) in
  (p0_avg, p1_avg)
