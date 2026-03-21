(** Bet-response subtree builder for action abstraction via RBM distance.

    Given a game state and a candidate bet size, builds a compact sampled
    tree representing the strategic consequences of that bet.  The tree
    captures the opponent's response distribution (fold/call/raise) and
    the resulting showdown values.

    These subtrees are compatible with {!Distance.compute} — two bet sizes
    whose response subtrees have small RBM distance can be merged with
    bounded EV error (Theorem 9.2 applies identically to action merging
    as to state merging). *)

(** Build a response subtree for a specific bet size at a given game state.

    The tree structure (2 plies deep):
    {v
      Root: "bet f"
      ├── Opponent Fold (leaf: fold equity = pot won)
      ├── Opponent Call → showdown distribution (MC sampled)
      └── Opponent Raise r → call leaf (showdown at raised pot)
    v}

    [pot] is the current pot before the bet.
    [effective_stack] is the smaller of the two players' remaining stacks.
    [bet_frac] is the fraction of pot to bet.
    [hole_cards] are the player's hole cards.
    [board_visible] is the currently visible board (3=flop, 4=turn, 5=river).
    [player] is 0 or 1 (determines value sign convention).

    Returns a [Nolimit_holdem.Node_label.t Tree.t] suitable for RBM distance
    computation against other bet sizes' response subtrees. *)
let build_bet_response_tree
    ~(pot : int)
    ~(effective_stack : int)
    ~(bet_frac : float)
    ~(hole_cards : Card.t * Card.t)
    ~(board_visible : Card.t list)
    ~(player : int)
    ?(max_opponents = 10)
    ?(max_board_samples = 3)
    ?(raise_fracs = [ 1.0; 2.0 ])
    ()
  : Nolimit_holdem.Node_label.t Tree.t =
  let bet_amount = Int.max 1 (Float.to_int (Float.of_int pot *. bet_frac)) in
  let bet_capped = Int.min bet_amount effective_stack in
  let pot_after_call = pot + bet_capped * 2 in  (* both players matched *)

  (* Fold leaf: we win the pot *)
  let fold_value =
    match player with
    | 0 -> Float.of_int pot
    | _ -> Float.of_int (-pot)
  in
  let fold_leaf =
    Tree.leaf
      ~label:(Nolimit_holdem.Node_label.Terminal { winners = [ player ]; pot })
      ~value:fold_value
  in

  (* Call branch: opponent calls, go to showdown.
     Use showdown_distribution_tree to sample outcomes. *)
  let call_showdown =
    let config : Nolimit_holdem.config =
      { deck = Card.full_deck
      ; small_blind = 1; big_blind = 2
      ; starting_stack = effective_stack + bet_capped
      ; bet_fractions = []; max_raises_per_round = 0; num_players = 2
      }
    in
    let raw_tree =
      Nolimit_holdem.showdown_distribution_tree
        ~max_opponents ~max_board_samples ~config
        ~player ~hole_cards ~board_visible ()
    in
    (* Scale values by pot_after_call / 2 to reflect actual payoff *)
    let scale = Float.of_int pot_after_call /. 2.0 in
    Tree.map_values raw_tree ~f:(fun v -> v *. scale)
  in

  (* Raise branches: opponent raises, we call (simplified — no re-raise tree) *)
  let raise_children =
    List.filter_map raise_fracs ~f:(fun r_frac ->
      let raise_amount =
        Int.max 1 (Float.to_int (Float.of_int pot_after_call *. r_frac))
      in
      let total_raise = bet_capped + raise_amount in
      match total_raise < effective_stack with
      | false -> None  (* can't raise this much *)
      | true ->
        let pot_after_raise = pot + total_raise * 2 in
        (* We call the raise — showdown *)
        let config : Nolimit_holdem.config =
          { deck = Card.full_deck
          ; small_blind = 1; big_blind = 2
          ; starting_stack = effective_stack
          ; bet_fractions = []; max_raises_per_round = 0; num_players = 2
          }
        in
        let raw_tree =
          Nolimit_holdem.showdown_distribution_tree
            ~max_opponents:(max_opponents / 2)
            ~max_board_samples:(Int.max 1 (max_board_samples / 2))
            ~config ~player ~hole_cards ~board_visible ()
        in
        let scale = Float.of_int pot_after_raise /. 2.0 in
        let scaled = Tree.map_values raw_tree ~f:(fun v -> v *. scale) in
        Some (Tree.node
          ~label:(Nolimit_holdem.Node_label.Chance {
            description = sprintf "raise_%.0f%%" (r_frac *. 100.0)
          })
          ~children:[ scaled ]))
  in

  (* Assemble: root node with fold, call, and raise children *)
  Tree.node
    ~label:(Nolimit_holdem.Node_label.Decision {
      player = 1 - player;  (* opponent decides *)
      actions_available = []
    })
    ~children:([ fold_leaf; call_showdown ] @ raise_children)

(** Build response subtrees for multiple bet sizes, averaged over sampled
    hands and boards.  Returns [(bet_frac, averaged_tree)] pairs.

    Averaging over hands produces a hand-independent tree for each bet size
    that captures the "typical" strategic consequences.  This is done via
    pointwise EV averaging (not tree merging) — we build one tree per hand
    per bet size and average the leaf values.

    [sample_hands] is a list of representative hole cards (e.g., one per
    equity decile).  [board_visible] is fixed for a given context. *)
let build_averaged_response_trees
    ~(pot : int)
    ~(effective_stack : int)
    ~(candidate_fracs : float list)
    ~(sample_hands : (Card.t * Card.t) list)
    ~(board_visible : Card.t list)
    ?(max_opponents = 10)
    ?(max_board_samples = 3)
    ()
  : (float * Nolimit_holdem.Node_label.t Tree.t) list =
  let n_hands = List.length sample_hands in
  let scale = 1.0 /. Float.of_int n_hands in
  List.map candidate_fracs ~f:(fun bet_frac ->
    (* Build a tree for each sample hand, average leaf values *)
    let trees = List.map sample_hands ~f:(fun hole_cards ->
      build_bet_response_tree ~pot ~effective_stack ~bet_frac
        ~hole_cards ~board_visible ~player:0
        ~max_opponents ~max_board_samples ())
    in
    (* Average by scaling each tree's values by 1/n_hands and summing.
       Since trees have the same structure (same bet_frac → same branching),
       we use the first tree's structure and average the values. *)
    let avg_tree =
      match trees with
      | [] -> failwith "build_averaged_response_trees: no sample hands"
      | [ single ] -> single
      | first :: rest ->
        List.fold rest ~init:(Tree.map_values first ~f:(fun v -> v *. scale))
          ~f:(fun acc t ->
            (* Merge by averaging values — both trees have same structure *)
            Merge.merge ~config:Merge.default_config acc (Tree.map_values t ~f:(fun v -> v *. scale)))
    in
    (bet_frac, avg_tree))
