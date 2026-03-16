(** Monte Carlo Counterfactual Regret Minimization for abstract Limit Hold'em.

    External-sampling MCCFR:  each iteration samples one complete deal
    (hole cards + board) and walks the betting tree for the *traverser*
    player.  At the traverser's decision nodes every action is explored;
    at the opponent's decision nodes a single action is sampled according
    to the current strategy.  Regrets are updated only for the traverser.

    The betting tree is never materialised -- we recurse through game
    states directly, mirroring {!Limit_holdem}'s betting logic. *)

(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type info_key = string

type strategy = (string, float array) Hashtbl.Poly.t

type cfr_state = {
  regret_sum : (string, float array) Hashtbl.Poly.t;
  strategy_sum : (string, float array) Hashtbl.Poly.t;
}

let create () =
  { regret_sum = Hashtbl.Poly.create ()
  ; strategy_sum = Hashtbl.Poly.create ()
  }

(* ------------------------------------------------------------------ *)
(* Action encoding                                                     *)
(* ------------------------------------------------------------------ *)

let action_char (a : Rhode_island.Action.t) =
  match a with
  | Fold  -> "f"
  | Check -> "k"
  | Call  -> "c"
  | Bet   -> "b"
  | Raise -> "r"

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
    match Hashtbl.find state.regret_sum key with
    | Some r -> r
    | None ->
      let r = Array.create ~len:num_actions 0.0 in
      Hashtbl.set state.regret_sum ~key ~data:r;
      r
  in
  regret_matching regrets

let accumulate_strategy (state : cfr_state) (key : info_key)
    (strat : float array) (weight : float) =
  let current =
    match Hashtbl.find state.strategy_sum key with
    | Some s -> s
    | None ->
      let s = Array.create ~len:(Array.length strat) 0.0 in
      Hashtbl.set state.strategy_sum ~key ~data:s;
      s
  in
  Array.iteri strat ~f:(fun i p ->
    current.(i) <- current.(i) +. weight *. p)

let average_strategy (state : cfr_state) : strategy =
  let result = Hashtbl.Poly.create () in
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

(** Build the info key for a given player at a given street.

    The key format is "B{preflop}:{flop}:{turn}:{river}|{history}"
    but we only include buckets up to the current street.
    - preflop:  "B{pf}|{history}"
    - flop:     "B{pf}:{fl}|{history}"
    - turn:     "B{pf}:{fl}:{tu}|{history}"
    - river:    "B{pf}:{fl}:{tu}:{ri}|{history}" *)
let make_info_key ~(buckets : int array) ~(round_idx : int) ~(history : string) : info_key =
  let buf = Buffer.create 32 in
  Buffer.add_char buf 'B';
  for i = 0 to Int.min round_idx 3 do
    match i with
    | 0 -> Buffer.add_string buf (Int.to_string buckets.(0))
    | _ ->
      Buffer.add_char buf ':';
      Buffer.add_string buf (Int.to_string buckets.(i))
  done;
  Buffer.add_char buf '|';
  Buffer.add_string buf history;
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Bucket computation per street                                       *)
(* ------------------------------------------------------------------ *)

(** Fast hand score for bucketing: evaluates the best hand rank using
    available cards and returns a score in [0.0, 1.0].

    Uses Hand_eval5 directly for 5 cards, Hand_eval7 for 6-7 cards.
    Maps (hand_rank, tiebreaker) to a normalised score for quantile
    bucketing.  This is much faster than Equity.hand_strength which
    enumerates all opponent hands. *)
let hand_score (hole_cards : Card.t * Card.t) (board_visible : Card.t list) : float =
  let (h1, h2) = hole_cards in
  let cards = [ h1; h2 ] @ board_visible in
  let n = List.length cards in
  let (rank, tiebreakers) =
    match n with
    | 7 -> Hand_eval7.evaluate7 cards
    | 6 ->
      (* Best of C(6,5)=6 subsets *)
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
      (* Shouldn't happen, but return a default *)
      (Hand_eval5.Hand_rank.High_card, [ 0 ])
  in
  (* Normalise: rank 0-8 maps to [0, 0.9], tiebreaker adds up to 0.1 *)
  let rank_score = Float.of_int (Hand_eval5.Hand_rank.to_int rank) /. 9.0 in
  let tb_score =
    match tiebreakers with
    | [] -> 0.0
    | first :: _ -> Float.of_int first /. 150.0  (* ranks go up to ~14 *)
  in
  Float.min 0.999 (rank_score +. tb_score *. 0.1)

(** Compute bucket for a hand at a given street using equity-based scoring.

    preflop: use the preflop abstraction (canonical hand -> bucket).
    flop/turn/river: evaluate the hand rank on visible board cards and
    quantise into n_buckets.  Uses direct hand evaluation (O(1) per call)
    rather than Equity.hand_strength (which enumerates all opponents). *)
let compute_bucket_equity
    ~(abstraction : Abstraction.abstraction_partial)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(round_idx : int)
  : int =
  match round_idx with
  | 0 ->
    (* Preflop: use the canonical-hand abstraction *)
    Abstraction.get_bucket abstraction ~hole_cards
  | _ ->
    (* Post-flop: evaluate hand rank directly and quantise *)
    let board_visible =
      match round_idx with
      | 1 -> List.take board 3    (* flop: 2+3=5 cards *)
      | 2 -> List.take board 4    (* turn: 2+4=6 cards *)
      | _ -> board                (* river: 2+5=7 cards *)
    in
    let score = hand_score hole_cards board_visible in
    let n = abstraction.n_buckets in
    Int.min (n - 1) (Float.to_int (score *. Float.of_int n))

(** Precompute all 4 street buckets for a given deal (equity-based). *)
let precompute_buckets_equity
    ~(abstraction : Abstraction.abstraction_partial)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
  : int array =
  Array.init 4 ~f:(fun round_idx ->
    compute_bucket_equity ~abstraction ~hole_cards ~board ~round_idx)

(* ------------------------------------------------------------------ *)
(* RBM-based post-flop bucketing                                       *)
(* ------------------------------------------------------------------ *)

(** Bucketing method selector.

    [Equity_based]: uses hand_score equity quantisation (fast but loses RBM
    error bounds from Theorem 9.2).
    [Rbm_based { epsilon; distance_config }]: builds information set trees
    for each street and clusters by RBM distance, preserving formal error
    bounds. *)
type bucket_method =
  | Equity_based
  | Rbm_based of { epsilon : float; distance_config : Distance.config }

(** A single postflop cluster: stores the representative IS tree and its
    cached EV for fast pre-filtering. *)
type postflop_cluster = {
  representative : Rhode_island.Node_label.t Tree.t;
  rep_ev : float;
  mutable member_count : int;
}

(** Per-street mutable cluster state for RBM-based bucketing. *)
type postflop_state = {
  clusters : (int, postflop_cluster list ref) Hashtbl.t;
  (** Keyed by street index: 1=flop, 2=turn, 3=river. *)
}

let create_postflop_state () =
  { clusters = Hashtbl.Poly.create ~size:4 () }

(** Find the nearest cluster for a tree among the existing clusters for
    a given street.  Uses EV pre-filtering: skip any cluster whose
    |EV difference| > epsilon.  Returns [(cluster_index, distance)] or
    [None] if no clusters exist. *)
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
              let d =
                Distance.compute_with_config ~config:distance_config
                  tree oc.representative
              in
              match Float.( < ) d best_d with
              | true -> (i, d)
              | false -> (best_i, best_d))
    in
    Some best

(** Compute bucket for a hand at a given post-flop street using RBM distance.

    Builds an information set tree for the player's hand + visible board,
    then finds or creates a cluster for this street.

    Returns the cluster index (= bucket ID). *)
let compute_bucket_rbm_postflop
    ~(game_config : Limit_holdem.config)
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
  (* Estimate pot at this street: blinds + small_bet rounds for prior streets *)
  let pot_so_far =
    let base = game_config.small_blind + game_config.big_blind in
    match round_idx with
    | 1 -> base + 2 * game_config.small_bet     (* after preflop call *)
    | 2 -> base + 4 * game_config.small_bet      (* after flop call *)
    | _ -> base + 4 * game_config.small_bet + 2 * game_config.big_bet
  in
  (* Build information set tree for this hand + visible board *)
  let is_tree =
    Limit_holdem.information_set_tree ~max_opponents:30 ~config:game_config
      ~player ~hole_cards ~board_visible ~round_idx ~pot_so_far ()
  in
  (* Get or create the cluster list for this street *)
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
       (* Close enough -- assign to existing cluster *)
       let oc = List.nth_exn clusters idx in
       oc.member_count <- oc.member_count + 1;
       idx
     | false ->
       (* Too far -- create new cluster *)
       let new_cluster =
         { representative = is_tree
         ; rep_ev = Tree.ev is_tree
         ; member_count = 1
         }
       in
       clusters_ref := clusters @ [ new_cluster ];
       List.length clusters)  (* new cluster index *)
  | None ->
    (* First cluster for this street *)
    let new_cluster =
      { representative = is_tree
      ; rep_ev = Tree.ev is_tree
      ; member_count = 1
      }
    in
    clusters_ref := [ new_cluster ];
    0

(** Compute bucket for a hand at a given street using RBM distance for
    post-flop streets.  Preflop uses the canonical-hand abstraction (same
    as equity-based).  Post-flop builds IS trees and clusters by RBM
    distance, preserving the formal error bounds of Theorem 9.2. *)
let compute_bucket_rbm
    ~(abstraction : Abstraction.abstraction_partial)
    ~(game_config : Limit_holdem.config)
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
    compute_bucket_rbm_postflop ~game_config ~epsilon ~distance_config
      ~postflop ~hole_cards ~board ~round_idx ~player

(** Precompute all 4 street buckets for a given deal (RBM-based).
    [player] = 0 or 1, used for building information set trees from the
    correct perspective. *)
let precompute_buckets_rbm
    ~(abstraction : Abstraction.abstraction_partial)
    ~(game_config : Limit_holdem.config)
    ~(epsilon : float)
    ~(distance_config : Distance.config)
    ~(postflop : postflop_state)
    ~(hole_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(player : int)
  : int array =
  Array.init 4 ~f:(fun round_idx ->
    compute_bucket_rbm ~abstraction ~game_config ~epsilon ~distance_config
      ~postflop ~hole_cards ~board ~round_idx ~player)

(** Backward-compatible alias: precompute_buckets uses equity-based method. *)
let precompute_buckets = precompute_buckets_equity

(* ------------------------------------------------------------------ *)
(* Inline betting tree traversal (no tree materialisation)             *)
(* ------------------------------------------------------------------ *)

(** Round state -- mirrors {!Limit_holdem.round_state}. *)
type round_state = {
  to_act : int;
  num_raises : int;
  bet_outstanding : bool;
  first_checked : bool;
  p1_invested : int;
  p2_invested : int;
  round_idx : int;
}

let bet_size_for_round (config : Limit_holdem.config) round_idx =
  match round_idx with
  | 0 | 1 -> config.small_bet
  | _     -> config.big_bet

(** Compute showdown payoff from P0's perspective.
    Positive = P0 wins, negative = P0 loses, zero = tie. *)
let showdown_payoff ~(p1_cards : Card.t * Card.t) ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list) ~(pot : int) : float =
  let (p1a, p1b) = p1_cards in
  let (p2a, p2b) = p2_cards in
  let hand1 = [ p1a; p1b ] @ board in
  let hand2 = [ p2a; p2b ] @ board in
  let cmp = Hand_eval7.compare_hands7 hand1 hand2 in
  match cmp > 0 with
  | true  -> Float.of_int (pot / 2)
  | false ->
    match cmp < 0 with
    | true  -> Float.of_int (-(pot / 2))
    | false -> 0.0

(** External-sampling MCCFR traversal.

    Returns the expected counterfactual value for the traverser at this node.
    Values are from P0's perspective internally; the sign flip for P1 is
    done at terminal nodes.

    At the traverser's decision nodes we explore ALL actions and update
    regrets.  At the opponent's decision nodes we sample ONE action
    according to the current strategy. *)
let rec mccfr_traverse
    ~(config : Limit_holdem.config)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(p1_buckets : int array)
    ~(p2_buckets : int array)
    ~(history : string)
    ~(state : round_state)
    ~(traverser : int)
    ~(cfr_states : cfr_state array)
  : float =
  let player = state.to_act in
  let pot = state.p1_invested + state.p2_invested in

  (* Determine available actions and their resulting states *)
  let bet_sz = bet_size_for_round config state.round_idx in
  let buckets =
    match player with
    | 0 -> p1_buckets
    | _ -> p2_buckets
  in
  let key = make_info_key ~buckets ~round_idx:state.round_idx ~history in

  match state.bet_outstanding with
  | true ->
    (* Facing a bet/raise: fold, call, or raise *)
    let can_raise = state.num_raises < config.max_raises in
    let num_actions = match can_raise with true -> 3 | false -> 2 in
    let cfr_st = cfr_states.(player) in
    let strat = get_strategy cfr_st key ~num_actions in

    let fold_payoff () =
      (* Folder loses: payoff from P0's perspective, flipped for traverser *)
      let p0_value =
        match player with
        | 0 -> Float.of_int (-(pot / 2))
        | _ -> Float.of_int (pot / 2)
      in
      match traverser with
      | 0 -> p0_value
      | _ -> Float.neg p0_value
    in
    let call_payoff () =
      let call_state = {
        state with
        bet_outstanding = false;
        p1_invested = (match player with 0 -> state.p1_invested + bet_sz | _ -> state.p1_invested);
        p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + bet_sz);
      } in
      let call_history = history ^ action_char Call in
      advance_to_next_round ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:call_history ~state:call_state ~traverser ~cfr_states
    in
    let raise_payoff () =
      let raise_state = {
        state with
        to_act = 1 - player;
        num_raises = state.num_raises + 1;
        bet_outstanding = true;
        p1_invested = (match player with 0 -> state.p1_invested + 2 * bet_sz | _ -> state.p1_invested);
        p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + 2 * bet_sz);
      } in
      let new_history = history ^ action_char Raise in
      mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:new_history ~state:raise_state
        ~traverser ~cfr_states
    in

    handle_decision ~player ~traverser ~cfr_st ~key ~strat ~num_actions
      ~action_payoffs:(fun i ->
        match i with
        | 0 -> fold_payoff ()
        | 1 -> call_payoff ()
        | _ -> raise_payoff ())

  | false ->
    (* No bet outstanding: check or bet *)
    let check_ends_round = state.first_checked in
    let can_bet = state.num_raises < config.max_raises in
    let num_actions = match can_bet with true -> 2 | false -> 1 in
    let cfr_st = cfr_states.(player) in
    let strat = get_strategy cfr_st key ~num_actions in

    let check_payoff () =
      let check_history = history ^ action_char Check in
      match check_ends_round with
      | true ->
        advance_to_next_round ~config ~p1_cards ~p2_cards ~board
          ~p1_buckets ~p2_buckets ~history:check_history ~state ~traverser ~cfr_states
      | false ->
        let check_state = {
          state with
          to_act = 1 - player;
          first_checked = true;
        } in
        mccfr_traverse ~config ~p1_cards ~p2_cards ~board
          ~p1_buckets ~p2_buckets ~history:check_history ~state:check_state
          ~traverser ~cfr_states
    in
    let bet_payoff () =
      let bet_state = {
        state with
        to_act = 1 - player;
        num_raises = state.num_raises + 1;
        bet_outstanding = true;
        first_checked = false;
        p1_invested = (match player with 0 -> state.p1_invested + bet_sz | _ -> state.p1_invested);
        p2_invested = (match player with 0 -> state.p2_invested | _ -> state.p2_invested + bet_sz);
      } in
      let new_history = history ^ action_char Bet in
      mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:new_history ~state:bet_state
        ~traverser ~cfr_states
    in

    handle_decision ~player ~traverser ~cfr_st ~key ~strat ~num_actions
      ~action_payoffs:(fun i ->
        match i with
        | 0 -> check_payoff ()
        | _ -> bet_payoff ())

(** Handle a decision node for either traverser or opponent.

    For traverser: explore all actions, compute regrets, return weighted value.
    For opponent: sample one action according to strategy, return that value. *)
and handle_decision ~(player : int) ~(traverser : int) ~(cfr_st : cfr_state)
    ~(key : info_key) ~(strat : float array) ~(num_actions : int)
    ~(action_payoffs : int -> float) : float =
  match player = traverser with
  | true ->
    (* Traverser: explore all actions *)
    accumulate_strategy cfr_st key strat 1.0;
    let action_values = Array.init num_actions ~f:action_payoffs in
    let node_value = Array.foldi action_values ~init:0.0 ~f:(fun i acc v ->
      acc +. strat.(i) *. v)
    in
    (* Update regrets *)
    let regrets =
      match Hashtbl.find cfr_st.regret_sum key with
      | Some r -> r
      | None ->
        let r = Array.create ~len:num_actions 0.0 in
        Hashtbl.set cfr_st.regret_sum ~key ~data:r;
        r
    in
    Array.iteri action_values ~f:(fun i v ->
      regrets.(i) <- regrets.(i) +. (v -. node_value));
    (* CFR+: clip regrets to non-negative *)
    Array.iteri regrets ~f:(fun i r ->
      match Float.( < ) r 0.0 with
      | true  -> regrets.(i) <- 0.0
      | false -> ignore r);
    node_value
  | false ->
    (* Opponent: sample one action *)
    accumulate_strategy cfr_st key strat 1.0;
    let r = Random.float 1.0 in
    let sampled = ref 0 in
    let cumul = ref strat.(0) in
    while !sampled < num_actions - 1 && Float.( < ) !cumul r do
      sampled := !sampled + 1;
      cumul := !cumul +. strat.(!sampled)
    done;
    action_payoffs !sampled

(** Advance to the next betting round or showdown. *)
and advance_to_next_round
    ~(config : Limit_holdem.config)
    ~(p1_cards : Card.t * Card.t)
    ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list)
    ~(p1_buckets : int array)
    ~(p2_buckets : int array)
    ~(history : string)
    ~(state : round_state)
    ~(traverser : int)
    ~(cfr_states : cfr_state array)
  : float =
  let next_round = state.round_idx + 1 in
  match next_round >= 4 with
  | true ->
    let pot = state.p1_invested + state.p2_invested in
    let value = showdown_payoff ~p1_cards ~p2_cards ~board ~pot in
    (* Return from traverser's perspective *)
    (match traverser with
     | 0 -> value
     | _ -> Float.neg value)
  | false ->
    let new_state = {
      state with
      to_act = 0;
      num_raises = 0;
      bet_outstanding = false;
      first_checked = false;
      round_idx = next_round;
    } in
    let new_history = history ^ "/" in
    mccfr_traverse ~config ~p1_cards ~p2_cards ~board
      ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
      ~traverser ~cfr_states

(* ------------------------------------------------------------------ *)
(* Top-level training loop                                             *)
(* ------------------------------------------------------------------ *)

(** Count total postflop clusters across all streets. *)
let postflop_cluster_count (postflop : postflop_state) : int =
  Hashtbl.fold postflop.clusters ~init:0 ~f:(fun ~key:_ ~data:clusters_ref acc ->
    acc + List.length !clusters_ref)

let train_mccfr ~(config : Limit_holdem.config)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(iterations : int)
    ?(report_every = 10_000)
    ?(bucket_method = Equity_based)
    ()
  : strategy * strategy =
  let cfr_states = [| create (); create () |] in
  let util_sum = ref 0.0 in
  (* Create shared postflop state for RBM bucketing (one per player) *)
  let postflop_states =
    match bucket_method with
    | Rbm_based _ -> [| create_postflop_state (); create_postflop_state () |]
    | Equity_based -> [| create_postflop_state (); create_postflop_state () |]
  in
  for iter = 1 to iterations do
    let (p1_cards, p2_cards, board) = sample_deal () in
    (* Precompute buckets for both players *)
    let p1_buckets, p2_buckets =
      match bucket_method with
      | Equity_based ->
        let b1 = precompute_buckets_equity ~abstraction ~hole_cards:p1_cards ~board in
        let b2 = precompute_buckets_equity ~abstraction ~hole_cards:p2_cards ~board in
        (b1, b2)
      | Rbm_based { epsilon; distance_config } ->
        let b1 = precompute_buckets_rbm ~abstraction ~game_config:config
            ~epsilon ~distance_config ~postflop:postflop_states.(0)
            ~hole_cards:p1_cards ~board ~player:0 in
        let b2 = precompute_buckets_rbm ~abstraction ~game_config:config
            ~epsilon ~distance_config ~postflop:postflop_states.(1)
            ~hole_cards:p2_cards ~board ~player:1 in
        (b1, b2)
    in
    (* Alternate traverser *)
    let traverser = (iter - 1) % 2 in
    (* Initial state: preflop with blinds *)
    let state = {
      to_act = 0;
      num_raises = 1;   (* BB's big blind counts as the first raise/bet *)
      bet_outstanding = true;
      first_checked = false;
      p1_invested = config.small_blind;
      p2_invested = config.big_blind;
      round_idx = 0;
    } in
    let value = mccfr_traverse ~config ~p1_cards ~p2_cards ~board
        ~p1_buckets ~p2_buckets ~history:"" ~state ~traverser ~cfr_states in
    util_sum := !util_sum +. value;
    (* Report progress *)
    match iter % report_every = 0 with
    | true ->
      let avg_util = !util_sum /. Float.of_int iter in
      let n_infosets_0 = Hashtbl.length cfr_states.(0).regret_sum in
      let n_infosets_1 = Hashtbl.length cfr_states.(1).regret_sum in
      (match bucket_method with
       | Equity_based ->
         printf "  [MCCFR-equity] iter %d/%d  avg_util=%.4f  infosets=(%d, %d)\n%!"
           iter iterations avg_util n_infosets_0 n_infosets_1
       | Rbm_based _ ->
         let n_clusters_0 = postflop_cluster_count postflop_states.(0) in
         let n_clusters_1 = postflop_cluster_count postflop_states.(1) in
         printf "  [MCCFR-rbm] iter %d/%d  avg_util=%.4f  infosets=(%d, %d)  postflop_clusters=(%d, %d)\n%!"
           iter iterations avg_util n_infosets_0 n_infosets_1
           n_clusters_0 n_clusters_1)
    | false -> ()
  done;
  let p0_avg = average_strategy cfr_states.(0) in
  let p1_avg = average_strategy cfr_states.(1) in
  (p0_avg, p1_avg)
