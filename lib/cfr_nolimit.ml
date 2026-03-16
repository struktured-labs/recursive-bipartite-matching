(** Monte Carlo Counterfactual Regret Minimization for No-Limit Hold'em.

    External-sampling MCCFR:  each iteration samples one complete deal
    (hole cards + board) and walks the betting tree for the *traverser*
    player.  At the traverser's decision nodes every action is explored;
    at the opponent's decision nodes a single action is sampled according
    to the current strategy.  Regrets are updated only for the traverser.

    Key differences from {!Cfr_abstract} (limit):
    1. Variable number of actions per decision node -- NL has
       2 + len(bet_fractions) + 1 (fold, check/call, each fraction, all-in).
    2. Stack-dependent actions -- available bets depend on remaining stack.
    3. Bet sizing in info key -- history encodes which bet fraction was chosen.
    4. Larger strategy tables -- more actions per node = more entries.

    The betting tree is never materialised -- we recurse through game
    states directly, mirroring {!Nolimit_holdem}'s action generation. *)

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
    but we only include buckets up to the current street. *)
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
(* Bucket computation per street (equity-based)                        *)
(* ------------------------------------------------------------------ *)

(** Fast hand score for bucketing: evaluates the best hand rank using
    available cards and returns a score in [0.0, 1.0]. *)
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
(* NL-specific round state                                             *)
(* ------------------------------------------------------------------ *)

(** Round state for NL inline traversal -- tracks stacks and investments
    for both players in heads-up. *)
type nl_state = {
  to_act : int;
  round_idx : int;
  num_raises : int;
  current_bet : int;         (** highest per-round bet this round *)
  p_invested : int array;    (** total invested by each player *)
  p_stack : int array;       (** remaining stack for each player *)
  round_start_invested : int array;  (** invested at start of this round *)
  actions_remaining : int;   (** players left to act before round closes *)
}

(* ------------------------------------------------------------------ *)
(* Action generation for inline traversal                              *)
(* ------------------------------------------------------------------ *)

(** Compute available actions at a decision node for heads-up NL.

    Returns a list of (action, history_char, resulting_state_update) where
    the update is a function that mutates copied arrays.

    Mirrors {!Nolimit_holdem.available_actions} but for inline CFR. *)
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
  (* Fold: only when facing a bet *)
  (match facing_bet with
   | true ->
     actions := (Nolimit_holdem.Action.Fold, "f") :: !actions
   | false -> ());
  (* Check or Call *)
  let check_call =
    match facing_bet with
    | true -> (Nolimit_holdem.Action.Call, "c")
    | false -> (Nolimit_holdem.Action.Check, "k")
  in
  actions := check_call :: !actions;
  (* Bet fractions *)
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
     (* All-in: only if we have more than to_call *)
     (match stack > to_call with
      | true ->
        actions := (Nolimit_holdem.Action.All_in, "a") :: !actions
      | false -> ())
   | false -> ());
  List.rev !actions

(** Apply an action to the NL state, returning the new state.
    Handles investment, stack, raise count, actions_remaining updates. *)
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
  let _ = new_round_start in  (* unchanged within a round *)
  let other = 1 - seat in
  match action with
  | Fold ->
    { state with
      to_act = other
    ; actions_remaining = 0  (* fold ends the hand *)
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
    ; actions_remaining = 1  (* opponent needs to act *)
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

(** Compute showdown payoff from the traverser's perspective.
    Positive = traverser wins, negative = traverser loses. *)
let showdown_payoff ~(p1_cards : Card.t * Card.t) ~(p2_cards : Card.t * Card.t)
    ~(board : Card.t list) ~(p_invested : int array) ~(traverser : int) : float =
  let (p1a, p1b) = p1_cards in
  let (p2a, p2b) = p2_cards in
  let hand1 = [ p1a; p1b ] @ board in
  let hand2 = [ p2a; p2b ] @ board in
  let cmp = Hand_eval7.compare_hands7 hand1 hand2 in
  let pot = p_invested.(0) + p_invested.(1) in
  (* P0's profit/loss *)
  let p0_value =
    match cmp > 0 with
    | true  -> Float.of_int (pot - p_invested.(0))
    | false ->
      match cmp < 0 with
      | true  -> Float.of_int (- p_invested.(0))
      | false -> 0.0  (* split pot *)
  in
  match traverser with
  | 0 -> p0_value
  | _ -> Float.neg p0_value

(* ------------------------------------------------------------------ *)
(* Inline betting tree traversal                                       *)
(* ------------------------------------------------------------------ *)

(** External-sampling MCCFR traversal for No-Limit Hold'em.

    Returns the expected counterfactual value for the traverser.
    At the traverser's decision nodes we explore ALL actions and update
    regrets.  At the opponent's decision nodes we sample ONE action
    according to the current strategy. *)
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

  (* Get available actions at this node *)
  let actions = available_actions_inline config state in
  let num_actions = List.length actions in

  match num_actions with
  | 0 ->
    (* No actions available -- advance to next round or showdown *)
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
        (* Folder loses their investment *)
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
        (* After call, check if round is over *)
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
        (* Raise/all-in: opponent needs to respond *)
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
  (* Check if either player is all-in *)
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
      actions_remaining = 2;  (* both players need to act in heads-up *)
    } in
    let new_history = history ^ "/" in
    mccfr_traverse ~config ~p1_cards ~p2_cards ~board
      ~p1_buckets ~p2_buckets ~history:new_history ~state:new_state
      ~traverser ~cfr_states

(* ------------------------------------------------------------------ *)
(* Top-level training loop                                             *)
(* ------------------------------------------------------------------ *)

let train_mccfr ~(config : Nolimit_holdem.config)
    ~(abstraction : Abstraction.abstraction_partial)
    ~(iterations : int)
    ?(report_every = 10_000)
    ()
  : strategy * strategy =
  let cfr_states = [| create (); create () |] in
  let util_sum = ref 0.0 in
  for iter = 1 to iterations do
    let (p1_cards, p2_cards, board) = sample_deal () in
    let p1_buckets =
      precompute_buckets_equity ~abstraction ~hole_cards:p1_cards ~board
    in
    let p2_buckets =
      precompute_buckets_equity ~abstraction ~hole_cards:p2_cards ~board
    in
    (* Alternate traverser *)
    let traverser = (iter - 1) % 2 in
    (* Initial state: preflop with blinds posted *)
    let p_invested = [| config.small_blind; config.big_blind |] in
    let p_stack = [|
      config.starting_stack - config.small_blind;
      config.starting_stack - config.big_blind;
    |] in
    let round_start_invested = [| config.small_blind; config.big_blind |] in
    let state = {
      to_act = 0;  (* SB acts first preflop in heads-up *)
      round_idx = 0;
      num_raises = 1;  (* BB counts as first bet *)
      current_bet = config.big_blind;
      p_invested;
      p_stack;
      round_start_invested;
      actions_remaining = 2;  (* both players need to act *)
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
      printf "  [MCCFR-NL] iter %d/%d  avg_util=%.4f  infosets=(%d, %d)\n%!"
        iter iterations avg_util n_infosets_0 n_infosets_1
    | false -> ()
  done;
  let p0_avg = average_strategy cfr_states.(0) in
  let p1_avg = average_strategy cfr_states.(1) in
  (p0_avg, p1_avg)
