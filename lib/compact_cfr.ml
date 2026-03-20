(** Compact-storage Monte Carlo CFR for No-Limit Hold'em.

    Drop-in replacement for {!Cfr_nolimit} that uses monomorphic
    [(string, _) Hashtbl.t] instead of [Hashtbl.Poly.t], cutting
    per-entry overhead by ~3x.  Tables are pre-sized to avoid
    expensive resize cascades.

    All game logic is identical to {!Cfr_nolimit}. *)

(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type info_key = string

type strategy = (string, float array) Hashtbl.t

type cfr_state = {
  regret_sum : (string, float array) Hashtbl.t;
  strategy_sum : (string, float array) Hashtbl.t;
}

let create ?(size = 1_000_000) () =
  { regret_sum = Hashtbl.create ~size (module String)
  ; strategy_sum = Hashtbl.create ~size (module String)
  }

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

let get_strategy (state : cfr_state) (key : info_key) ~(num_actions : int) : float array =
  let regrets =
    Hashtbl.find_or_add state.regret_sum key
      ~default:(fun () -> Array.create ~len:num_actions 0.0)
  in
  regret_matching regrets

let accumulate_strategy (state : cfr_state) (key : info_key)
    (strat : float array) (weight : float) =
  let current =
    Hashtbl.find_or_add state.strategy_sum key
      ~default:(fun () -> Array.create ~len:(Array.length strat) 0.0)
  in
  Array.iteri strat ~f:(fun i p ->
    current.(i) <- current.(i) +. weight *. p)

let average_strategy (state : cfr_state) : strategy =
  let result = Hashtbl.create ~size:(Hashtbl.length state.strategy_sum) (module String) in
  Hashtbl.iteri state.strategy_sum ~f:(fun ~key ~data:sums ->
    let total = Array.fold sums ~init:0.0 ~f:( +. ) in
    let avg =
      match Float.( > ) total 0.0 with
      | true  -> Array.map sums ~f:(fun s -> s /. total)
      | false ->
        let n = Array.length sums in
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
(* Bucket-based info-set key                                           *)
(* ------------------------------------------------------------------ *)

(** Write the decimal digits of non-negative [n] into [buf] starting at [pos].
    Returns the new position after the last digit written.
    Avoids [Int.to_string] allocation on the hot path. *)
let write_int_digits (buf : Bytes.t) (pos : int) (n : int) : int =
  match n with
  | 0 ->
    Bytes.set buf pos '0';
    pos + 1
  | _ ->
    (* Count digits *)
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

let make_info_key ~(buckets : int array) ~(round_idx : int) ~(history : string) : info_key =
  let history_len = String.length history in
  (* Upper bound: 'B' + up to 4 bucket ints (max ~7 digits each) + 3 colons
     + '|' + history.  40 bytes covers the prefix generously. *)
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

let available_actions_inline (config : Nolimit_holdem.config) (state : nl_state)
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
     List.iter config.bet_fractions ~f:(fun frac ->
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
  let actions = available_actions_inline config state in
  let num_actions = List.length actions in

  match num_actions with
  | 0 ->
    advance_to_next_round ~config ~p1_cards ~p2_cards ~board
      ~p1_buckets ~p2_buckets ~history ~state ~traverser ~cfr_states
  | _ ->
    let cfr_st = cfr_states.(player) in
    let strat = get_strategy cfr_st key ~num_actions in
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
      ~action_payoffs:action_payoff

and handle_decision ~(player : int) ~(traverser : int) ~(cfr_st : cfr_state)
    ~(key : info_key) ~(strat : float array) ~(num_actions : int)
    ~(action_payoffs : int -> float) : float =
  match player = traverser with
  | true ->
    accumulate_strategy cfr_st key strat 1.0;
    let action_values = Array.init num_actions ~f:action_payoffs in
    let node_value = Array.foldi action_values ~init:0.0 ~f:(fun i acc v ->
      acc +. strat.(i) *. v)
    in
    let regrets =
      Hashtbl.find_or_add cfr_st.regret_sum key
        ~default:(fun () -> Array.create ~len:num_actions 0.0)
    in
    Array.iteri action_values ~f:(fun i v ->
      regrets.(i) <- regrets.(i) +. (v -. node_value));
    Array.iteri regrets ~f:(fun i r ->
      match Float.( < ) r 0.0 with
      | true  -> regrets.(i) <- 0.0
      | false -> ignore r);
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

(** Magic header for the chunked binary format (8 bytes). *)
let chunked_magic = "RBMCFR01"

(* -- Legacy Marshal format (kept for backward compat) --------------- *)

let load_checkpoint_marshal ~(filename : string) : cfr_state array =
  let ic = In_channel.create filename in
  let (p0_regret, p0_strat, p1_regret, p1_strat) :
    (string * float array) list * (string * float array) list *
    (string * float array) list * (string * float array) list =
    Marshal.from_channel ic
  in
  In_channel.close ic;
  let to_hashtbl lst =
    let tbl = Hashtbl.create (module String) ~size:(List.length lst) in
    List.iter lst ~f:(fun (k, v) -> Hashtbl.set tbl ~key:k ~data:v);
    tbl
  in
  [| { regret_sum = to_hashtbl p0_regret; strategy_sum = to_hashtbl p0_strat }
   ; { regret_sum = to_hashtbl p1_regret; strategy_sum = to_hashtbl p1_strat }
  |]

let save_checkpoint_marshal ~(filename : string) (cfr_states : cfr_state array) : unit =
  let hashtbl_to_alist tbl =
    Hashtbl.fold tbl ~init:[] ~f:(fun ~key ~data acc -> (key, data) :: acc)
  in
  let data =
    ( hashtbl_to_alist cfr_states.(0).regret_sum
    , hashtbl_to_alist cfr_states.(0).strategy_sum
    , hashtbl_to_alist cfr_states.(1).regret_sum
    , hashtbl_to_alist cfr_states.(1).strategy_sum )
  in
  let oc = Out_channel.create filename in
  Marshal.to_channel oc data [];
  Out_channel.close oc

(* -- Chunked binary format (streaming, no memory spike) ------------- *)

(** Binary layout:
    {[
      magic      : 8 bytes  "RBMCFR01"
      version    : 4 bytes  (int32-le, currently 1)
      n_tables   : 4 bytes  (int32-le, always 4)
      -- for each table:
        n_entries  : 8 bytes (int64-le)
        -- for each entry:
          key_len    : 4 bytes (int32-le)
          key_bytes  : key_len bytes
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

let read_int32_le (ic : In_channel.t) : int =
  let buf = Bytes.create 4 in
  let n = In_channel.input ic ~buf ~pos:0 ~len:4 in
  match n = 4 with
  | true ->
    Char.to_int (Bytes.get buf 0)
    lor (Char.to_int (Bytes.get buf 1) lsl 8)
    lor (Char.to_int (Bytes.get buf 2) lsl 16)
    lor (Char.to_int (Bytes.get buf 3) lsl 24)
  | false -> failwith "read_int32_le: unexpected EOF"

let read_int64_le (ic : In_channel.t) : int =
  let buf = Bytes.create 8 in
  let n = In_channel.input ic ~buf ~pos:0 ~len:8 in
  match n = 8 with
  | true ->
    let v = ref 0 in
    for i = 0 to 7 do
      v := !v lor (Char.to_int (Bytes.get buf i) lsl (i * 8))
    done;
    !v
  | false -> failwith "read_int64_le: unexpected EOF"

let write_hashtbl_chunked (oc : Out_channel.t) (tbl : (string, float array) Hashtbl.t) : unit =
  let n_entries = Hashtbl.length tbl in
  write_int64_le oc n_entries;
  Hashtbl.iteri tbl ~f:(fun ~key ~data ->
    let key_len = String.length key in
    write_int32_le oc key_len;
    Out_channel.output_string oc key;
    let arr_len = Array.length data in
    write_int32_le oc arr_len;
    (* Write float array as raw bytes — 8 bytes per float, native endian *)
    let float_buf = Bytes.create (arr_len * 8) in
    Array.iteri data ~f:(fun i f ->
      let bits = Int64.bits_of_float f in
      for b = 0 to 7 do
        Bytes.set float_buf ((i * 8) + b)
          (Char.of_int_exn (Int64.to_int_exn (Int64.( land ) (Int64.shift_right_logical bits (b * 8)) 0xFFL)))
      done);
    Out_channel.output oc ~buf:float_buf ~pos:0 ~len:(arr_len * 8))

let read_hashtbl_chunked (ic : In_channel.t) : (string, float array) Hashtbl.t =
  let n_entries = read_int64_le ic in
  let tbl = Hashtbl.create (module String) ~size:n_entries in
  for _ = 1 to n_entries do
    let key_len = read_int32_le ic in
    let key_buf = Bytes.create key_len in
    let n_read = In_channel.input ic ~buf:key_buf ~pos:0 ~len:key_len in
    (match n_read = key_len with
     | true -> ()
     | false -> failwith "read_hashtbl_chunked: unexpected EOF reading key");
    let key = Bytes.to_string key_buf in
    let arr_len = read_int32_le ic in
    let float_buf = Bytes.create (arr_len * 8) in
    let n_read = In_channel.input ic ~buf:float_buf ~pos:0 ~len:(arr_len * 8) in
    (match n_read = arr_len * 8 with
     | true -> ()
     | false -> failwith "read_hashtbl_chunked: unexpected EOF reading floats");
    let data = Array.init arr_len ~f:(fun i ->
      let bits = ref 0L in
      for b = 0 to 7 do
        bits := Int64.( lor ) !bits
          (Int64.shift_left (Int64.of_int_exn (Char.to_int (Bytes.get float_buf ((i * 8) + b)))) (b * 8))
      done;
      Int64.float_of_bits !bits) in
    Hashtbl.set tbl ~key ~data
  done;
  tbl

let save_checkpoint_chunked ~(filename : string) (cfr_states : cfr_state array) : unit =
  let oc = Out_channel.create filename in
  (* Magic header *)
  Out_channel.output_string oc chunked_magic;
  (* Version *)
  write_int32_le oc 1;
  (* Number of tables *)
  write_int32_le oc 4;
  (* Write all 4 tables: P0 regret, P0 strategy, P1 regret, P1 strategy *)
  write_hashtbl_chunked oc cfr_states.(0).regret_sum;
  write_hashtbl_chunked oc cfr_states.(0).strategy_sum;
  write_hashtbl_chunked oc cfr_states.(1).regret_sum;
  write_hashtbl_chunked oc cfr_states.(1).strategy_sum;
  Out_channel.close oc

let load_checkpoint_chunked ~(filename : string) : cfr_state array =
  let ic = In_channel.create filename in
  (* Read and verify magic *)
  let magic_buf = Bytes.create 8 in
  let n = In_channel.input ic ~buf:magic_buf ~pos:0 ~len:8 in
  (match n = 8 && String.equal (Bytes.to_string magic_buf) chunked_magic with
   | true -> ()
   | false -> failwithf "load_checkpoint_chunked: bad magic in %s" filename ());
  (* Version *)
  let version = read_int32_le ic in
  (match version = 1 with
   | true -> ()
   | false -> failwithf "load_checkpoint_chunked: unsupported version %d" version ());
  (* Number of tables *)
  let n_tables = read_int32_le ic in
  (match n_tables = 4 with
   | true -> ()
   | false -> failwithf "load_checkpoint_chunked: expected 4 tables, got %d" n_tables ());
  (* Read all 4 tables *)
  let p0_regret = read_hashtbl_chunked ic in
  let p0_strat = read_hashtbl_chunked ic in
  let p1_regret = read_hashtbl_chunked ic in
  let p1_strat = read_hashtbl_chunked ic in
  In_channel.close ic;
  [| { regret_sum = p0_regret; strategy_sum = p0_strat }
   ; { regret_sum = p1_regret; strategy_sum = p1_strat }
  |]

(* -- Auto-detecting load -------------------------------------------- *)

let is_chunked_format ~(filename : string) : bool =
  let ic = In_channel.create filename in
  let buf = Bytes.create 8 in
  let n = In_channel.input ic ~buf ~pos:0 ~len:8 in
  In_channel.close ic;
  n = 8 && String.equal (Bytes.to_string buf) chunked_magic

(** [load_checkpoint] auto-detects the format (chunked vs Marshal). *)
let load_checkpoint ~(filename : string) : cfr_state array =
  match is_chunked_format ~filename with
  | true  -> load_checkpoint_chunked ~filename
  | false -> load_checkpoint_marshal ~filename

(** [save_checkpoint] uses the chunked format by default. *)
let save_checkpoint ~(filename : string) (cfr_states : cfr_state array) : unit =
  save_checkpoint_chunked ~filename cfr_states

let train_mccfr ~(config : Nolimit_holdem.config)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(iterations : int)
    ?(report_every = 10_000)
    ?(initial_size = 1_000_000)
    ?(checkpoint_every = 0)
    ?(checkpoint_prefix = "checkpoint")
    ?(resume_from : string option)
    ?(bucket_method : bucket_method = Equity_based)
    ()
  : strategy * strategy =
  let cfr_states =
    match resume_from with
    | Some filename ->
      printf "  [Resume] Loading checkpoint from %s ...\n%!" filename;
      let states = load_checkpoint ~filename in
      printf "  [Resume] Loaded P0=%d P1=%d info sets. Continuing training.\n%!"
        (Hashtbl.length states.(0).regret_sum)
        (Hashtbl.length states.(1).regret_sum);
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
    let value = mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:"" ~state ~traverser ~cfr_states in
    util_sum := !util_sum +. value;
    (match iter % report_every = 0 with
     | true ->
       let avg_util = !util_sum /. Float.of_int iter in
       let n_infosets_0 = Hashtbl.length cfr_states.(0).regret_sum in
       let n_infosets_1 = Hashtbl.length cfr_states.(1).regret_sum in
       printf "  [Compact-MCCFR-NL] iter %d/%d  avg_util=%.4f  infosets=(%d, %d)\n%!"
         iter iterations avg_util n_infosets_0 n_infosets_1
     | false -> ());
    (match checkpoint_every > 0 && iter % checkpoint_every = 0 with
     | true ->
       let filename = sprintf "%s_%d.dat" checkpoint_prefix iter in
       printf "  [Checkpoint] Saving %s ...\n%!" filename;
       save_checkpoint ~filename cfr_states;
       printf "  [Checkpoint] Done.\n%!"
     | false -> ())
  done;
  let p0_avg = average_strategy cfr_states.(0) in
  let p1_avg = average_strategy cfr_states.(1) in
  (p0_avg, p1_avg)

(* ------------------------------------------------------------------ *)
(* Parallel MCCFR training                                            *)
(* ------------------------------------------------------------------ *)

(** Copy a cfr_state by deep-copying each hash table entry. *)
let copy_cfr_state (src : cfr_state) : cfr_state =
  let copy_tbl tbl =
    let tbl2 = Hashtbl.create (module String) ~size:(Hashtbl.length tbl) in
    Hashtbl.iteri tbl ~f:(fun ~key ~data ->
      Hashtbl.set tbl2 ~key ~data:(Array.copy data));
    tbl2
  in
  { regret_sum = copy_tbl src.regret_sum
  ; strategy_sum = copy_tbl src.strategy_sum
  }

(** Merge [src] into [dst] by summing regret_sum and strategy_sum arrays
    element-wise.  Mutates [dst] in place. *)
let merge_cfr_state_into ~(dst : cfr_state) ~(src : cfr_state) : unit =
  let merge_tbl ~dst_tbl ~src_tbl =
    Hashtbl.iteri src_tbl ~f:(fun ~key ~data:src_arr ->
      match Hashtbl.find dst_tbl key with
      | Some dst_arr ->
        Array.iteri src_arr ~f:(fun i v ->
          dst_arr.(i) <- dst_arr.(i) +. v)
      | None ->
        Hashtbl.set dst_tbl ~key ~data:(Array.copy src_arr))
  in
  merge_tbl ~dst_tbl:dst.regret_sum ~src_tbl:src.regret_sum;
  merge_tbl ~dst_tbl:dst.strategy_sum ~src_tbl:src.strategy_sum

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
    ()
  : strategy * strategy =
  let num_workers = Int.max 1 num_domains in
  printf "  [Parallel-MCCFR] Starting %d domains, %d iterations total\n%!"
    num_workers iterations;
  (* Load or create the base state *)
  let base_states =
    match resume_from with
    | Some filename ->
      printf "  [Resume] Loading checkpoint from %s ...\n%!" filename;
      let states = load_checkpoint ~filename in
      printf "  [Resume] Loaded P0=%d P1=%d info sets.\n%!"
        (Hashtbl.length states.(0).regret_sum)
        (Hashtbl.length states.(1).regret_sum);
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
     checkpoint to every worker (that would use N × 90GB+ of RAM).
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
          let value = mccfr_traverse ~config ~p1_cards ~p2_cards ~board
              ~p1_buckets ~p2_buckets ~history:"" ~state ~traverser
              ~cfr_states:my_states in
          local_util_sum := !local_util_sum +. value;
          let total = Atomic.fetch_and_add global_iter 1 + 1 in
          (match total % report_every = 0 with
           | true ->
             let n0 = Hashtbl.length my_states.(0).regret_sum in
             let n1 = Hashtbl.length my_states.(1).regret_sum in
             printf "  [Parallel-MCCFR] ~%d/%d iters (worker %d: %d/%d)  infosets=(%d,%d)\n%!"
               total iterations worker_id iter my_iters n0 n1
           | false -> ())
        done;
        worker_utils.(worker_id) <- !local_util_sum));
  Domainslib.Task.teardown_pool pool;
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
    (Hashtbl.length merged.(0).regret_sum)
    (Hashtbl.length merged.(1).regret_sum);
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
