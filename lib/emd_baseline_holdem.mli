(** EMD baseline for Mini Texas Hold'em (2 hole cards, 3 community).

    Same approach as {!Emd_baseline} but adapted for 2-hole-card hands
    and 5-card evaluation via {!Hand_eval5}. *)

(** A deal: player 1's 2 hole cards paired with the 3 community cards. *)
type deal = {
  p1_cards : Card.t * Card.t;
  community : Card.t list;
}

(** Compute the showdown distribution for player 1 holding [p1_cards]
    against all possible 2-card opponent hands from the remaining deck,
    given [community] cards. *)
val compute_distribution
  :  deck:Card.t list
  -> p1_cards:Card.t * Card.t
  -> community:Card.t list
  -> Emd_baseline.hand_distribution
