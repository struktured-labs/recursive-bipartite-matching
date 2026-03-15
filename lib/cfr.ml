(** Counterfactual Regret Minimization for Rhode Island Hold'em. *)

type info_key = string

type strategy = (info_key, float array) Hashtbl.Poly.t

type cfr_state = {
  regret_sum : (info_key, float array) Hashtbl.Poly.t;
  strategy_sum : (info_key, float array) Hashtbl.Poly.t;
  iterations : int;
}

let create () =
  { regret_sum = Hashtbl.Poly.create ()
  ; strategy_sum = Hashtbl.Poly.create ()
  ; iterations = 0
  }

let action_char (a : Rhode_island.Action.t) =
  match a with
  | Fold -> "f"
  | Check -> "k"
  | Call -> "c"
  | Bet -> "b"
  | Raise -> "r"

let regret_matching (regrets : float array) : float array =
  let n = Array.length regrets in
  let positive = Array.map regrets ~f:(fun r -> Float.max 0.0 r) in
  let total = Array.fold positive ~init:0.0 ~f:( +. ) in
  match Float.( > ) total 0.0 with
  | true -> Array.map positive ~f:(fun p -> p /. total)
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

let accumulate_strategy (state : cfr_state) (key : info_key) (strat : float array)
    (weight : float) =
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

let compute_average_strategy (state : cfr_state) : strategy =
  let result = Hashtbl.Poly.create () in
  Hashtbl.iteri state.strategy_sum ~f:(fun ~key ~data:sums ->
    let total = Array.fold sums ~init:0.0 ~f:( +. ) in
    let avg =
      match Float.( > ) total 0.0 with
      | true -> Array.map sums ~f:(fun s -> s /. total)
      | false ->
        let n = Array.length sums in
        Array.create ~len:n (1.0 /. Float.of_int n)
    in
    Hashtbl.set result ~key ~data:avg);
  result

(** Core CFR traversal for a specific deal. *)
let rec cfr_traverse
    ~(tree : Rhode_island.Node_label.t Tree.t)
    ~(history : string)
    ~(p1_card : Card.t)
    ~(p2_card : Card.t)
    ~(p0_reach : float)
    ~(p1_reach : float)
    ~(traverser : int)
    ~(states : cfr_state array)
    ~(info_key_fn : int -> Card.t -> string -> info_key)
  : float =
  match tree with
  | Leaf { value; _ } ->
    (match traverser with
     | 0 -> value
     | _ -> Float.neg value)
  | Node { label; children } ->
    (match label with
     | Root | Chance _ ->
       let n = List.length children in
       let weight = 1.0 /. Float.of_int n in
       List.fold children ~init:0.0 ~f:(fun acc child ->
         acc +. weight *. cfr_traverse
           ~tree:child ~history ~p1_card ~p2_card
           ~p0_reach:(p0_reach *. weight)
           ~p1_reach:(p1_reach *. weight)
           ~traverser ~states ~info_key_fn)
     | Decision { player; actions_available } ->
       let card =
         match player with
         | 0 -> p1_card
         | _ -> p2_card
       in
       let key = info_key_fn player card history in
       let num_actions = List.length actions_available in
       let state = states.(player) in
       let strat = get_strategy state key ~num_actions in
       let my_reach =
         match player with
         | 0 -> p0_reach
         | _ -> p1_reach
       in
       accumulate_strategy state key strat my_reach;
       let actions_arr = Array.of_list actions_available in
       let children_arr = Array.of_list children in
       let action_values = Array.init num_actions ~f:(fun i ->
         let action = actions_arr.(i) in
         let child = children_arr.(i) in
         let new_history = history ^ action_char action in
         let new_p0_reach, new_p1_reach =
           match player with
           | 0 -> (p0_reach *. strat.(i), p1_reach)
           | _ -> (p0_reach, p1_reach *. strat.(i))
         in
         cfr_traverse
           ~tree:child ~history:new_history ~p1_card ~p2_card
           ~p0_reach:new_p0_reach ~p1_reach:new_p1_reach
           ~traverser ~states ~info_key_fn)
       in
       let node_value = Array.foldi action_values ~init:0.0 ~f:(fun i acc v ->
         acc +. strat.(i) *. v)
       in
       (match player = traverser with
        | true ->
          let opp_reach =
            match player with
            | 0 -> p1_reach
            | _ -> p0_reach
          in
          let regrets =
            match Hashtbl.find state.regret_sum key with
            | Some r -> r
            | None ->
              let r = Array.create ~len:num_actions 0.0 in
              Hashtbl.set state.regret_sum ~key ~data:r;
              r
          in
          Array.iteri action_values ~f:(fun i v ->
            regrets.(i) <- regrets.(i) +. opp_reach *. (v -. node_value));
          (* CFR+: clip regrets to non-negative *)
          Array.iteri regrets ~f:(fun i r ->
            match Float.( < ) r 0.0 with
            | true -> regrets.(i) <- 0.0
            | false -> ignore r)
        | false -> ());
       node_value
     | Terminal { winner; pot } ->
       let value =
         match winner with
         | Some 0 -> Float.of_int (pot / 2)
         | Some _ -> Float.of_int (-(pot / 2))
         | None -> 0.0
       in
       (match traverser with
        | 0 -> value
        | _ -> Float.neg value))

let standard_info_key (_player : int) (card : Card.t) (history : string) : info_key =
  Card.to_string card ^ "|" ^ history

let enumerate_deals ~(config : Rhode_island.config) ~(community : Card.t list) =
  let deck = config.deck in
  let available =
    List.fold community ~init:deck ~f:(fun d c ->
      List.filter d ~f:(fun x -> not (Card.equal x c)))
  in
  let deals = ref [] in
  List.iter available ~f:(fun p1 ->
    let rest = List.filter available ~f:(fun x -> not (Card.equal x p1)) in
    List.iter rest ~f:(fun p2 ->
      deals := (p1, p2) :: !deals));
  List.rev !deals

let available_cards ~(config : Rhode_island.config) ~(community : Card.t list) =
  List.fold community ~init:config.deck ~f:(fun d c ->
    List.filter d ~f:(fun x -> not (Card.equal x c)))

let train ~(config : Rhode_island.config) ~(community : Card.t list) ~(iterations : int)
  : strategy * strategy =
  let states = [| create (); create () |] in
  let deals = enumerate_deals ~config ~community in
  let deal_trees =
    List.map deals ~f:(fun (p1, p2) ->
      let tree = Rhode_island.game_tree_for_deal ~config ~p1_card:p1 ~p2_card:p2 ~community in
      (p1, p2, tree))
  in
  for _iter = 1 to iterations do
    List.iter deal_trees ~f:(fun (p1_card, p2_card, tree) ->
      let (_ : float) = cfr_traverse
        ~tree ~history:"" ~p1_card ~p2_card
        ~p0_reach:1.0 ~p1_reach:1.0
        ~traverser:0 ~states
        ~info_key_fn:standard_info_key
      in
      let (_ : float) = cfr_traverse
        ~tree ~history:"" ~p1_card ~p2_card
        ~p0_reach:1.0 ~p1_reach:1.0
        ~traverser:1 ~states
        ~info_key_fn:standard_info_key
      in
      ())
  done;
  let p1_avg = compute_average_strategy states.(0) in
  let p2_avg = compute_average_strategy states.(1) in
  (p1_avg, p2_avg)

(** Evaluate a deal tree under a strategy profile (P0's perspective). *)
let rec eval_deal
    ~(tree : Rhode_island.Node_label.t Tree.t)
    ~(history : string)
    ~(p1_card : Card.t)
    ~(p2_card : Card.t)
    ~(p0_strat : strategy)
    ~(p1_strat : strategy)
    ~(info_key_fn : int -> Card.t -> string -> info_key)
  : float =
  match tree with
  | Leaf { value; _ } -> value
  | Node { label; children } ->
    (match label with
     | Root | Chance _ ->
       let n = List.length children in
       let weight = 1.0 /. Float.of_int n in
       List.fold children ~init:0.0 ~f:(fun acc child ->
         acc +. weight *. eval_deal ~tree:child ~history ~p1_card ~p2_card
           ~p0_strat ~p1_strat ~info_key_fn)
     | Decision { player; actions_available } ->
       let card =
         match player with
         | 0 -> p1_card
         | _ -> p2_card
       in
       let key = info_key_fn player card history in
       let num_actions = List.length actions_available in
       let strat_table =
         match player with
         | 0 -> p0_strat
         | _ -> p1_strat
       in
       let strat =
         match Hashtbl.find strat_table key with
         | Some s -> s
         | None -> Array.create ~len:num_actions (1.0 /. Float.of_int num_actions)
       in
       let actions_arr = Array.of_list actions_available in
       let children_arr = Array.of_list children in
       Array.foldi strat ~init:0.0 ~f:(fun i acc prob ->
         let action = actions_arr.(i) in
         let child = children_arr.(i) in
         let new_history = history ^ action_char action in
         acc +. prob *. eval_deal ~tree:child ~history:new_history
           ~p1_card ~p2_card ~p0_strat ~p1_strat ~info_key_fn)
     | Terminal { winner; pot } ->
       (match winner with
        | Some 0 -> Float.of_int (pot / 2)
        | Some _ -> Float.of_int (-(pot / 2))
        | None -> 0.0))

(** Compute exploitability correctly using information-set-aware best response.

    For each player, find the strategy that maximizes expected value
    against the opponent's fixed strategy, subject to the constraint
    that the player's action at each info set is a single choice
    (independent of opponent's hidden card).

    For each card [my_card] the BR player might hold:
    1. Walk all deals (my_card vs each opponent card)
    2. At each BR player info set, accumulate action values across opponent cards
    3. Pick the argmax action per info set
    4. Evaluate the resulting BR strategy

    Exploitability = BR0_gain + BR1_gain where gain = BR_value - profile_value. *)
let exploitability_with_key_fn ~(config : Rhode_island.config) ~(community : Card.t list)
    ~(info_key_fn : int -> Card.t -> string -> info_key)
    (p0_strategy : strategy) (p1_strategy : strategy) : float =
  let available = available_cards ~config ~community in
  let n_cards = Float.of_int (List.length available) in

  let compute_br_value ~(br_player : int) ~(opp_strategy : strategy) : float =
    (* For each BR player card, compute best response and evaluate *)
    let total_ev =
      List.fold available ~init:0.0 ~f:(fun card_acc my_card ->
        let opp_cards = List.filter available ~f:(fun c ->
          not (Card.equal c my_card)) in
        let n_opps = Float.of_int (List.length opp_cards) in

        (* Accumulate action values per info set across opponent cards *)
        let action_ev : (info_key, float array) Hashtbl.Poly.t =
          Hashtbl.Poly.create ()
        in

        (* For each opponent card, walk the tree.
           At BR player nodes, compute value of each action recursively.
           At opponent nodes, follow opponent strategy. *)
        List.iter opp_cards ~f:(fun opp_card ->
          let p1_card, p2_card =
            match br_player with
            | 0 -> (my_card, opp_card)
            | _ -> (opp_card, my_card)
          in
          let tree = Rhode_island.game_tree_for_deal ~config
              ~p1_card ~p2_card ~community in

          let rec walk ~(tree : Rhode_island.Node_label.t Tree.t) ~(history : string)
            : float =
            match tree with
            | Leaf { value; _ } ->
              (match br_player with
               | 0 -> value
               | _ -> Float.neg value)
            | Node { label; children } ->
              (match label with
               | Root | Chance _ ->
                 let n = List.length children in
                 let w = 1.0 /. Float.of_int n in
                 List.fold children ~init:0.0 ~f:(fun acc child ->
                   acc +. w *. walk ~tree:child ~history)
               | Decision { player; actions_available } ->
                 let card =
                   match player with
                   | 0 -> p1_card
                   | _ -> p2_card
                 in
                 let key = info_key_fn player card history in
                 let num_actions = List.length actions_available in
                 let actions_arr = Array.of_list actions_available in
                 let children_arr = Array.of_list children in
                 (match player = br_player with
                  | true ->
                    (* Compute value of each action *)
                    let vals = Array.init num_actions ~f:(fun i ->
                      let action = actions_arr.(i) in
                      let child = children_arr.(i) in
                      let h = history ^ action_char action in
                      walk ~tree:child ~history:h) in
                    (* Accumulate into info set table *)
                    let accum =
                      match Hashtbl.find action_ev key with
                      | Some a -> a
                      | None ->
                        let a = Array.create ~len:num_actions 0.0 in
                        Hashtbl.set action_ev ~key ~data:a;
                        a
                    in
                    Array.iteri vals ~f:(fun i v ->
                      accum.(i) <- accum.(i) +. v);
                    (* For this specific opponent, return the max value.
                       This is an approximation for the recursive walk
                       but the final evaluation uses the proper BR strategy. *)
                    Array.fold vals ~init:Float.neg_infinity ~f:Float.max
                  | false ->
                    let strat =
                      match Hashtbl.find opp_strategy key with
                      | Some s -> s
                      | None ->
                        Array.create ~len:num_actions
                          (1.0 /. Float.of_int num_actions)
                    in
                    Array.foldi strat ~init:0.0 ~f:(fun i acc prob ->
                      let action = actions_arr.(i) in
                      let child = children_arr.(i) in
                      let h = history ^ action_char action in
                      acc +. prob *. walk ~tree:child ~history:h))
               | Terminal { winner; pot } ->
                 let value =
                   match winner with
                   | Some 0 -> Float.of_int (pot / 2)
                   | Some _ -> Float.of_int (-(pot / 2))
                   | None -> 0.0
                 in
                 (match br_player with
                  | 0 -> value
                  | _ -> Float.neg value))
          in
          let (_ : float) = walk ~tree ~history:"" in
          ());

        (* Build pure BR strategy from accumulated action values *)
        let br_strat = Hashtbl.Poly.create () in
        Hashtbl.iteri action_ev ~f:(fun ~key ~data:vals ->
          let num_actions = Array.length vals in
          let best_i = ref 0 in
          let best_v = ref vals.(0) in
          for i = 1 to num_actions - 1 do
            match Float.( > ) vals.(i) !best_v with
            | true -> best_i := i; best_v := vals.(i)
            | false -> ()
          done;
          let s = Array.create ~len:num_actions 0.0 in
          s.(!best_i) <- 1.0;
          Hashtbl.set br_strat ~key ~data:s);

        (* Evaluate BR strategy for this card *)
        let card_ev =
          List.fold opp_cards ~init:0.0 ~f:(fun acc opp_card ->
            let p1_card, p2_card =
              match br_player with
              | 0 -> (my_card, opp_card)
              | _ -> (opp_card, my_card)
            in
            let tree = Rhode_island.game_tree_for_deal ~config
                ~p1_card ~p2_card ~community in
            let p0_s, p1_s =
              match br_player with
              | 0 -> (br_strat, opp_strategy)
              | _ -> (opp_strategy, br_strat)
            in
            let v = eval_deal ~tree ~history:"" ~p1_card ~p2_card
                ~p0_strat:p0_s ~p1_strat:p1_s ~info_key_fn in
            let v_br =
              match br_player with
              | 0 -> v
              | _ -> Float.neg v
            in
            acc +. v_br)
          /. n_opps
        in
        card_acc +. card_ev)
    in
    total_ev /. n_cards
  in

  let br0 = compute_br_value ~br_player:0 ~opp_strategy:p1_strategy in
  let br1 = compute_br_value ~br_player:1 ~opp_strategy:p0_strategy in

  (* Game value under the strategy profile *)
  let deals = enumerate_deals ~config ~community in
  let num_deals = Float.of_int (List.length deals) in
  let game_val =
    List.fold deals ~init:0.0 ~f:(fun acc (p1_card, p2_card) ->
      let tree = Rhode_island.game_tree_for_deal ~config
          ~p1_card ~p2_card ~community in
      acc +. eval_deal ~tree ~history:"" ~p1_card ~p2_card
        ~p0_strat:p0_strategy ~p1_strat:p1_strategy ~info_key_fn)
    /. num_deals
  in

  (* Exploit = gain for P0 via BR + gain for P1 via BR
     game_val is from P0's perspective, so P1's game value = -game_val *)
  let exploit = (br0 -. game_val) +. (br1 +. game_val) in
  Float.max 0.0 exploit

let exploitability ~(config : Rhode_island.config) ~(community : Card.t list)
    (p0_strategy : strategy) (p1_strategy : strategy) : float =
  exploitability_with_key_fn ~config ~community
    ~info_key_fn:standard_info_key p0_strategy p1_strategy

let build_cluster_map
    ~(config : Rhode_island.config)
    ~(community : Card.t list)
    ~(ev_graph : Rhode_island.Node_label.t Ev_graph.t)
  : (Card.t, int) Hashtbl.Poly.t =
  let map = Hashtbl.Poly.create () in
  let available = available_cards ~config ~community in
  List.iter available ~f:(fun card ->
    let is_tree = Rhode_island.information_set_tree
        ~config ~player:0 ~hole_card:card ~community in
    let (cluster_idx, _dist) = Ev_graph.find_cluster ev_graph is_tree in
    Hashtbl.set map ~key:card ~data:cluster_idx);
  map

let compressed_info_key
    (cluster_map : (Card.t, int) Hashtbl.Poly.t)
    (_player : int)
    (card : Card.t)
    (history : string)
  : info_key =
  let cluster_idx =
    match Hashtbl.find cluster_map card with
    | Some idx -> idx
    | None -> -1
  in
  sprintf "C%d|%s" cluster_idx history

let train_compressed
    ~(config : Rhode_island.config)
    ~(community : Card.t list)
    ~(ev_graph : Rhode_island.Node_label.t Ev_graph.t)
    ~(iterations : int)
  : strategy * strategy * (int -> Card.t -> string -> info_key) =
  let cluster_map = build_cluster_map ~config ~community ~ev_graph in
  let states = [| create (); create () |] in
  let deals = enumerate_deals ~config ~community in
  let deal_trees =
    List.map deals ~f:(fun (p1, p2) ->
      let tree = Rhode_island.game_tree_for_deal ~config ~p1_card:p1 ~p2_card:p2 ~community in
      (p1, p2, tree))
  in
  let info_key_fn = compressed_info_key cluster_map in
  for _iter = 1 to iterations do
    List.iter deal_trees ~f:(fun (p1_card, p2_card, tree) ->
      let (_ : float) = cfr_traverse
        ~tree ~history:"" ~p1_card ~p2_card
        ~p0_reach:1.0 ~p1_reach:1.0
        ~traverser:0 ~states
        ~info_key_fn
      in
      let (_ : float) = cfr_traverse
        ~tree ~history:"" ~p1_card ~p2_card
        ~p0_reach:1.0 ~p1_reach:1.0
        ~traverser:1 ~states
        ~info_key_fn
      in
      ())
  done;
  let p1_compressed = compute_average_strategy states.(0) in
  let p2_compressed = compute_average_strategy states.(1) in
  (p1_compressed, p2_compressed, info_key_fn)
