(** CFR+ style regret pruning.

    Standalone module that removes dominated information sets (those where
    all cumulative regrets are negative) from a {!Compact_cfr.cfr_state}.
    These info sets contribute zero probability mass under regret matching
    and can be safely discarded to reduce memory pressure.

    This module does NOT modify {!Compact_cfr} — it operates externally
    on the exposed [cfr_state] hashtables. *)

(** [should_prune_regrets regrets] returns [true] when every element of
    [regrets] is strictly negative, meaning the info set is dominated and
    regret matching would assign uniform probability (no positive regret
    to exploit).  Returns [false] for empty arrays and for arrays where
    any element is >= 0. *)
val should_prune_regrets : float array -> bool

(** [prune_state state] scans all entries in [state.entries] and
    removes those where {!should_prune_regrets} is [true] for the
    entry's regrets.  The entire entry (regrets + strategy) is removed.
    Returns the number of pruned entries. *)
val prune_state : Compact_cfr.cfr_state -> pruned:int ref -> unit

(** [prune_periodically ~every ~iter state] calls {!prune_state} when
    [iter mod every = 0].  A no-op otherwise.  Intended to be called
    once per MCCFR iteration inside a training loop. *)
val prune_periodically : every:int -> iter:int -> Compact_cfr.cfr_state -> unit
