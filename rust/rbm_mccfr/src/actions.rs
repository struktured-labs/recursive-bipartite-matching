/// NL Hold'em actions and game state for inline traversal.
/// Matches OCaml's available_actions_inline and apply_action in compact_cfr.ml.

use arrayvec::ArrayVec;
use crate::config::GameConfig;

/// Action type matching OCaml's Nolimit_holdem.Action.t
#[derive(Clone, Copy, Debug)]
pub enum Action {
    Fold,
    Check,
    Call,
    BetFrac(f64),
    AllIn,
}

impl Action {
    /// History character matching OCaml's to_history_char exactly.
    pub fn to_history_char(self) -> u8 {
        match self {
            Action::Fold => b'f',
            Action::Check => b'k',
            Action::Call => b'c',
            Action::BetFrac(f) if (f - 0.25).abs() < 1e-9 => b'q',
            Action::BetFrac(f) if (f - 0.33).abs() < 1e-9 => b't',
            Action::BetFrac(f) if (f - 0.5).abs() < 1e-9 => b'h',
            Action::BetFrac(f) if (f - 0.75).abs() < 1e-9 => b'r',
            Action::BetFrac(f) if (f - 1.0).abs() < 1e-9 => b'p',
            Action::BetFrac(f) if (f - 1.5).abs() < 1e-9 => b'o',
            Action::BetFrac(f) if (f - 2.0).abs() < 1e-9 => b'd',
            Action::BetFrac(_) => b'b', // fallback for unknown fractions
            Action::AllIn => b'a',
        }
    }
}

/// Game state during traversal (stack-allocated, Copy).
#[derive(Clone, Copy, Debug)]
pub struct NlState {
    pub to_act: u8,
    pub round_idx: u8,
    pub num_raises: u8,
    pub actions_remaining: u8,
    pub current_bet: i32,
    pub p_invested: [i32; 2],
    pub p_stack: [i32; 2],
    pub round_start_invested: [i32; 2],
}

/// Stack-allocated history buffer. Avoids string allocation in hot loop.
pub struct HistoryBuf {
    pub data: [u8; 64],
    pub len: u8,
}

impl HistoryBuf {
    pub fn new() -> Self {
        Self {
            data: [0; 64],
            len: 0,
        }
    }

    #[inline(always)]
    pub fn push(&mut self, ch: u8) {
        self.data[self.len as usize] = ch;
        self.len += 1;
    }

    #[inline(always)]
    pub fn pop(&mut self) {
        self.len -= 1;
    }

    #[inline(always)]
    pub fn push_slash(&mut self) {
        self.push(b'/');
    }

    #[inline(always)]
    pub fn as_slice(&self) -> &[u8] {
        &self.data[..self.len as usize]
    }
}

/// Generate available actions at a decision point.
/// Returns up to 12 (action, history_char) pairs in a stack-allocated vector.
pub fn available_actions(
    config: &GameConfig,
    state: &NlState,
) -> ArrayVec<(Action, u8), 12> {
    let mut actions = ArrayVec::new();
    let seat = state.to_act as usize;
    let stack = state.p_stack[seat];
    let already_in_round = state.p_invested[seat] - state.round_start_invested[seat];
    let to_call = (state.current_bet - already_in_round).min(stack);
    let facing_bet = to_call > 0;
    let pot: i32 = state.p_invested.iter().sum();
    let can_raise = state.num_raises < config.max_raises_per_round && stack > to_call;

    // Fold (only when facing a bet)
    if facing_bet {
        actions.push((Action::Fold, b'f'));
    }

    // Check or Call
    if facing_bet {
        actions.push((Action::Call, b'c'));
    } else {
        actions.push((Action::Check, b'k'));
    }

    if can_raise {
        let pot_after_call = pot + to_call;
        for &frac in &config.bet_fractions {
            let raise_amount = (pot_after_call as f64 * frac) as i32;
            let raise_amount = raise_amount.max(1);
            let total_to_put_in = to_call + raise_amount;
            if total_to_put_in < stack {
                let action = Action::BetFrac(frac);
                actions.push((action, action.to_history_char()));
            }
        }
        // All-in
        if stack > to_call {
            actions.push((Action::AllIn, b'a'));
        }
    }

    actions
}

/// Apply an action to produce a new game state.
pub fn apply_action(config: &GameConfig, state: NlState, action: Action) -> NlState {
    let seat = state.to_act as usize;
    let mut new_state = state;
    let already_in_round = state.p_invested[seat] - state.round_start_invested[seat];
    let to_call = (state.current_bet - already_in_round).min(state.p_stack[seat]);

    match action {
        Action::Fold => {
            // Player folds — mark by setting stack to -1 (sentinel)
            new_state.p_stack[seat] = -1;
            new_state.actions_remaining = new_state.actions_remaining.saturating_sub(1);
        }
        Action::Check => {
            new_state.actions_remaining = new_state.actions_remaining.saturating_sub(1);
        }
        Action::Call => {
            new_state.p_invested[seat] += to_call;
            new_state.p_stack[seat] -= to_call;
            new_state.actions_remaining = new_state.actions_remaining.saturating_sub(1);
        }
        Action::BetFrac(frac) => {
            let pot: i32 = new_state.p_invested.iter().sum();
            let pot_after_call = pot + to_call;
            let raise_amount = ((pot_after_call as f64 * frac) as i32).max(1);
            let total = to_call + raise_amount;
            new_state.p_invested[seat] += total;
            new_state.p_stack[seat] -= total;
            let in_round = new_state.p_invested[seat] - state.round_start_invested[seat];
            new_state.current_bet = in_round;
            new_state.num_raises += 1;
            // Everyone else needs to act again
            new_state.actions_remaining = 1; // heads-up: only opponent
        }
        Action::AllIn => {
            let all_in = state.p_stack[seat];
            new_state.p_invested[seat] += all_in;
            new_state.p_stack[seat] = 0;
            if all_in > to_call {
                let in_round = new_state.p_invested[seat] - state.round_start_invested[seat];
                // Use max to match OCaml: all-in for less than current bet
                // doesn't reduce the bet level (prevents spurious game states)
                new_state.current_bet = new_state.current_bet.max(in_round);
                new_state.num_raises += 1;
                new_state.actions_remaining = 1;
            } else {
                new_state.actions_remaining = new_state.actions_remaining.saturating_sub(1);
            }
        }
    }

    // Advance to_act
    new_state.to_act = 1 - state.to_act;

    new_state
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_history_buf() {
        let mut buf = HistoryBuf::new();
        buf.push(b'c');
        buf.push(b'c');
        buf.push_slash();
        buf.push(b'k');
        assert_eq!(buf.as_slice(), b"cc/k");
        buf.pop();
        assert_eq!(buf.as_slice(), b"cc/");
    }

    #[test]
    fn test_action_chars() {
        assert_eq!(Action::Fold.to_history_char(), b'f');
        assert_eq!(Action::Check.to_history_char(), b'k');
        assert_eq!(Action::Call.to_history_char(), b'c');
        assert_eq!(Action::BetFrac(0.5).to_history_char(), b'h');
        assert_eq!(Action::BetFrac(1.0).to_history_char(), b'p');
        assert_eq!(Action::BetFrac(2.0).to_history_char(), b'd');
        assert_eq!(Action::AllIn.to_history_char(), b'a');
    }

    #[test]
    fn test_available_actions_preflop() {
        let config = GameConfig::slumbot();
        let state = NlState {
            to_act: 0,
            round_idx: 0,
            num_raises: 1,
            actions_remaining: 2,
            current_bet: 100, // BB
            p_invested: [50, 100],
            p_stack: [19950, 19900],
            round_start_invested: [50, 100],
        };
        let actions = available_actions(&config, &state);
        // SB facing BB: fold, call, bet_half, bet_pot, bet_double, all-in
        assert!(actions.len() >= 4, "Expected at least 4 actions, got {}", actions.len());
    }
}
