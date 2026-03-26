/// MCCFR traversal engine — the hot loop.
///
/// External-sampling MCCFR: for the traverser, explore all actions.
/// For the opponent, sample one action from the current strategy.
///
/// Uses CompactCfrState (arena-backed i16 storage) for ~3x memory savings.

use crate::actions::{self, HistoryBuf, NlState};
use crate::card::Card;
use crate::cfr_state::DcfrTable;
use crate::compact_state::{self, CompactCfrState};
use crate::config::GameConfig;
use crate::hand_eval_fast;
use crate::info_key;

/// Showdown: evaluate both hands, return payoff from P0's perspective.
fn showdown_payoff(
    p1_cards: &[Card; 2],
    p2_cards: &[Card; 2],
    board: &[Card; 5],
    p_invested: &[i32; 2],
    traverser: u8,
) -> f64 {
    let mut h1 = [0u8; 7];
    h1[0] = p1_cards[0];
    h1[1] = p1_cards[1];
    h1[2..7].copy_from_slice(board);

    let mut h2 = [0u8; 7];
    h2[0] = p2_cards[0];
    h2[1] = p2_cards[1];
    h2[2..7].copy_from_slice(board);

    let cmp = hand_eval_fast::compare_hands7_fast(&h1, &h2);
    let pot = p_invested[0] + p_invested[1];

    let p0_value = if cmp > 0 {
        (pot - p_invested[0]) as f64 // P0 wins
    } else if cmp < 0 {
        -(p_invested[0] as f64) // P0 loses
    } else {
        0.0 // Tie
    };

    if traverser == 0 {
        p0_value
    } else {
        -p0_value
    }
}

/// Advance to the next betting round or showdown.
fn advance_to_next_round(
    config: &GameConfig,
    p1_cards: &[Card; 2],
    p2_cards: &[Card; 2],
    board: &[Card; 5],
    p1_buckets: &[u32; 4],
    p2_buckets: &[u32; 4],
    history: &mut HistoryBuf,
    state: NlState,
    traverser: u8,
    cfr_states: &mut [CompactCfrState; 2],
    rng: &mut impl rand::Rng,
    lcfr_iter: u32,
    prune_threshold: f32,
    dcfr_epoch: u16,
    dcfr_table: Option<&DcfrTable>,
) -> f64 {
    let next_round = state.round_idx + 1;

    // Check for fold (stack == -1 sentinel)
    let p0_folded = state.p_stack[0] < 0;
    let p1_folded = state.p_stack[1] < 0;

    if p0_folded || p1_folded {
        let winner = if p0_folded { 1u8 } else { 0u8 };
        let pot = state.p_invested[0] + state.p_invested[1];
        let p0_value = if winner == 0 {
            (pot - state.p_invested[0]) as f64
        } else {
            -(state.p_invested[0] as f64)
        };
        return if traverser == 0 { p0_value } else { -p0_value };
    }

    if next_round >= 4 {
        // Showdown
        return showdown_payoff(p1_cards, p2_cards, board, &state.p_invested, traverser);
    }

    // Check if only one player can act (other all-in)
    let p0_can_act = state.p_stack[0] > 0;
    let p1_can_act = state.p_stack[1] > 0;
    let can_act_count = p0_can_act as u8 + p1_can_act as u8;

    if can_act_count <= 1 {
        // Everyone all-in or only one can act — run out to showdown
        return showdown_payoff(p1_cards, p2_cards, board, &state.p_invested, traverser);
    }

    // New round
    let new_state = NlState {
        to_act: 0, // Post-flop: P0 (SB) acts first
        round_idx: next_round,
        num_raises: 0,
        actions_remaining: can_act_count,
        current_bet: 0,
        p_invested: state.p_invested,
        p_stack: state.p_stack,
        round_start_invested: state.p_invested,
    };

    history.push_slash();
    let result = mccfr_traverse(
        config,
        p1_cards,
        p2_cards,
        board,
        p1_buckets,
        p2_buckets,
        history,
        new_state,
        traverser,
        cfr_states,
        rng,
        lcfr_iter,
        prune_threshold,
        dcfr_epoch,
        dcfr_table,
    );
    history.pop(); // remove slash
    result
}

/// Core MCCFR traversal. Returns counterfactual value for the traverser.
///
/// When `dcfr_table` is Some, lazy DCFR discounting is applied on access.
/// `dcfr_epoch` is `iteration / 1000` (only used when dcfr_table is Some).
pub fn mccfr_traverse(
    config: &GameConfig,
    p1_cards: &[Card; 2],
    p2_cards: &[Card; 2],
    board: &[Card; 5],
    p1_buckets: &[u32; 4],
    p2_buckets: &[u32; 4],
    history: &mut HistoryBuf,
    state: NlState,
    traverser: u8,
    cfr_states: &mut [CompactCfrState; 2],
    rng: &mut impl rand::Rng,
    lcfr_iter: u32,
    prune_threshold: f32,
    dcfr_epoch: u16,
    dcfr_table: Option<&DcfrTable>,
) -> f64 {
    let player = state.to_act;
    let buckets = if player == 0 { p1_buckets } else { p2_buckets };
    let key = info_key::make_info_key(buckets, state.round_idx, history.as_slice());

    let avail = actions::available_actions(config, &state);
    let num_actions = avail.len();

    if num_actions == 0 {
        return advance_to_next_round(
            config,
            p1_cards,
            p2_cards,
            board,
            p1_buckets,
            p2_buckets,
            history,
            state,
            traverser,
            cfr_states,
            rng,
            lcfr_iter,
            prune_threshold,
            dcfr_epoch,
            dcfr_table,
        );
    }

    // Get or create strategy via regret matching
    let na = num_actions as u8;
    let mut strat = [0.0f32; 12];
    let mut pruned = [false; 12];

    {
        let cfr_st = &mut cfr_states[player as usize];
        let entry = match dcfr_table {
            Some(dt) => cfr_st.find_or_add_lazy_dcfr(key, na, dcfr_epoch, dt),
            None => cfr_st.find_or_add(key, na),
        };

        if player == traverser && prune_threshold.is_finite() {
            compact_state::regret_matching_pruned(cfr_st, &entry, prune_threshold, &mut strat[..num_actions], &mut pruned[..num_actions]);
        } else {
            compact_state::regret_matching(cfr_st, &entry, &mut strat[..num_actions]);
        }
    }

    if player == traverser {
        // Traverser: explore all actions, update regrets
        let mut action_values = [0.0f64; 12];

        for (i, &(action, ch)) in avail.iter().enumerate() {
            if pruned[i] {
                action_values[i] = 0.0;
                continue;
            }
            let new_state = actions::apply_action(config, state, action);
            history.push(ch);

            // Check for fold
            let folded = new_state.p_stack[state.to_act as usize] < 0;
            if folded {
                // Fold terminal
                let pot = new_state.p_invested[0] + new_state.p_invested[1];
                let winner = 1 - state.to_act;
                let p0_value = if winner == 0 {
                    (pot - new_state.p_invested[0]) as f64
                } else {
                    -(new_state.p_invested[0] as f64)
                };
                action_values[i] = if traverser == 0 { p0_value } else { -p0_value };
            } else if new_state.actions_remaining == 0 {
                action_values[i] = advance_to_next_round(
                    config, p1_cards, p2_cards, board, p1_buckets, p2_buckets,
                    history, new_state, traverser, cfr_states, rng, lcfr_iter, prune_threshold,
                    dcfr_epoch, dcfr_table,
                );
            } else {
                action_values[i] = mccfr_traverse(
                    config, p1_cards, p2_cards, board, p1_buckets, p2_buckets,
                    history, new_state, traverser, cfr_states, rng, lcfr_iter, prune_threshold,
                    dcfr_epoch, dcfr_table,
                );
            }

            history.pop();
        }

        // Node value
        let mut node_value = 0.0f64;
        for i in 0..num_actions {
            node_value += strat[i] as f64 * action_values[i];
        }

        // Update regrets and strategy
        {
            let cfr_st = &mut cfr_states[player as usize];
            // Entry was already lazily discounted above; no need to discount again.
            // find_or_add returns a Copy handle (CompactEntry).
            let entry = cfr_st.find_or_add(key, na);

            // Accumulate strategy (with LCFR weighting)
            compact_state::accumulate_strategy(cfr_st, &entry, &strat[..num_actions], 1.0, lcfr_iter);

            // Update regrets
            for i in 0..num_actions {
                if !pruned[i] {
                    let regret_delta = (action_values[i] - node_value) as f32;
                    cfr_st.add_regret(&entry, i, regret_delta);
                }
            }

            // CFR+: floor negative regrets to zero
            for i in 0..num_actions {
                if cfr_st.regret(&entry, i) < 0.0 {
                    cfr_st.set_regret(&entry, i, 0.0);
                }
            }
        }

        node_value
    } else {
        // Opponent: sample one action from strategy
        let r: f32 = rng.gen();
        let mut cumulative = 0.0f32;
        let mut chosen = num_actions - 1;
        for i in 0..num_actions {
            cumulative += strat[i];
            if r < cumulative {
                chosen = i;
                break;
            }
        }

        let (action, ch) = avail[chosen];
        let new_state = actions::apply_action(config, state, action);
        history.push(ch);

        let value = if new_state.p_stack[state.to_act as usize] < 0 {
            // Fold
            let pot = new_state.p_invested[0] + new_state.p_invested[1];
            let winner = 1 - state.to_act;
            let p0_value = if winner == 0 {
                (pot - new_state.p_invested[0]) as f64
            } else {
                -(new_state.p_invested[0] as f64)
            };
            if traverser == 0 { p0_value } else { -p0_value }
        } else if new_state.actions_remaining == 0 {
            advance_to_next_round(
                config, p1_cards, p2_cards, board, p1_buckets, p2_buckets,
                history, new_state, traverser, cfr_states, rng, lcfr_iter, prune_threshold,
                dcfr_epoch, dcfr_table,
            )
        } else {
            mccfr_traverse(
                config, p1_cards, p2_cards, board, p1_buckets, p2_buckets,
                history, new_state, traverser, cfr_states, rng, lcfr_iter, prune_threshold,
                dcfr_epoch, dcfr_table,
            )
        };

        history.pop();
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::card;
    use rand::Rng;
    use rand::SeedableRng;
    use rand_xoshiro::Xoshiro256PlusPlus;

    #[test]
    fn test_traverse_doesnt_panic() {
        let config = GameConfig::slumbot();
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
        let mut cfr_states = [CompactCfrState::new(1000), CompactCfrState::new(1000)];

        for _ in 0..100 {
            let (p1, p2, board) = card::sample_deal(&mut rng);
            let p1_buckets = [0u32; 4]; // dummy buckets
            let p2_buckets = [0u32; 4];
            let mut history = HistoryBuf::new();
            let state = NlState {
                to_act: 0,
                round_idx: 0,
                num_raises: 1,
                actions_remaining: 2,
                current_bet: config.big_blind,
                p_invested: [config.small_blind, config.big_blind],
                p_stack: [
                    config.starting_stack - config.small_blind,
                    config.starting_stack - config.big_blind,
                ],
                round_start_invested: [config.small_blind, config.big_blind],
            };
            let traverser = (rng.gen::<u32>() % 2) as u8;
            let _value = mccfr_traverse(
                &config, &p1, &p2, &board, &p1_buckets, &p2_buckets,
                &mut history, state, traverser, &mut cfr_states, &mut rng, 0, f32::INFINITY,
                0, None,
            );
        }
        // Should have created some info sets
        assert!(cfr_states[0].len() > 0);
        assert!(cfr_states[1].len() > 0);
    }

    #[test]
    fn test_traverse_1000_iters() {
        let config = GameConfig::slumbot();
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(123);
        let mut cfr_states = [CompactCfrState::new(10000), CompactCfrState::new(10000)];

        let mut util_sum = 0.0;
        for iter in 0..1000 {
            let (p1, p2, board) = card::sample_deal(&mut rng);
            let p1_buckets = [(p1[0] as u32 / 4) % 10; 4];
            let p2_buckets = [(p2[0] as u32 / 4) % 10; 4];
            let mut history = HistoryBuf::new();
            let state = NlState {
                to_act: 0,
                round_idx: 0,
                num_raises: 1,
                actions_remaining: 2,
                current_bet: config.big_blind,
                p_invested: [config.small_blind, config.big_blind],
                p_stack: [
                    config.starting_stack - config.small_blind,
                    config.starting_stack - config.big_blind,
                ],
                round_start_invested: [config.small_blind, config.big_blind],
            };
            let traverser = (iter % 2) as u8;
            let value = mccfr_traverse(
                &config, &p1, &p2, &board, &p1_buckets, &p2_buckets,
                &mut history, state, traverser, &mut cfr_states, &mut rng, 0, f32::INFINITY,
                0, None,
            );
            util_sum += value;
        }

        let avg_util = util_sum / 1000.0;
        eprintln!("1000 iters: avg_util={:.2}, P0={} P1={} info sets",
            avg_util, cfr_states[0].len(), cfr_states[1].len());

        // Should converge vaguely toward 0
        assert!(avg_util.abs() < 500.0, "avg_util too extreme: {}", avg_util);
    }
}
