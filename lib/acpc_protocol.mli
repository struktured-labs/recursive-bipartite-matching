(** ACPC (Annual Computer Poker Competition) protocol parser for Limit Hold'em.

    Parses MATCHSTATE messages from the ACPC dealer and selects actions
    using a trained CFR strategy with card abstraction.

    Protocol format:
    {v MATCHSTATE:position:hand_number:betting_history:cards v}

    Where:
    - position: 0 or 1 (which seat this bot is in)
    - hand_number: integer
    - betting_history: actions separated by '/' for street boundaries
      - 'f' = fold, 'c' = call/check, 'r' = raise/bet
    - cards: hole cards | board cards (flop|turn|river)

    Reference: {{: http://www.computerpokercompetition.org } ACPC protocol spec} *)

(** Parsed ACPC match state. *)
type matchstate = {
  position : int;
  hand_number : int;
  betting : string;
  hole_cards : Card.t * Card.t;
  board : Card.t list;
  current_street : int;
  is_our_turn : bool;
}

(** Parse an ACPC card string like "Ah" into a [Card.t].
    Rank chars: 2-9, T, J, Q, K, A.  Suit chars: c, d, h, s. *)
val parse_card : string -> Card.t

(** Parse an ACPC MATCHSTATE line into a [matchstate].
    Raises [Failure] on malformed input. *)
val parse_matchstate : string -> matchstate

(** Format an action as an ACPC action character: "f", "c", or "r". *)
val format_action : [< `Fold | `Call | `Raise ] -> string

(** Determine valid actions from the current betting state.
    Returns a subset of [`Fold; `Call; `Raise] based on the
    betting history and Limit Hold'em rules. *)
val valid_actions : matchstate -> [ `Fold | `Call | `Raise ] list

(** Convert ACPC betting string to internal action history encoding.
    ACPC uses f/c/r; internal uses f/k/c/b/r with street separators. *)
val acpc_to_internal_history : string -> string

(** Choose an action given a trained strategy and card abstraction.

    Looks up the information set key from the matchstate, finds the
    strategy distribution, and samples an action proportionally. *)
val choose_action
  :  matchstate:matchstate
  -> strategy:(string, float array) Hashtbl.Poly.t
  -> abstraction:Abstraction.abstraction
  -> [ `Fold | `Call | `Raise ]
