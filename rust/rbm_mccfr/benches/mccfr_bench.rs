use criterion::{criterion_group, criterion_main, Criterion};
use rand::SeedableRng;
use rand_xoshiro::Xoshiro256PlusPlus;

use rbm_mccfr::actions::{HistoryBuf, NlState};
use rbm_mccfr::buckets;
use rbm_mccfr::card;
use rbm_mccfr::cfr_state::CfrState;
use rbm_mccfr::config::GameConfig;
use rbm_mccfr::traversal;

fn bench_info_key_hash(c: &mut Criterion) {
    c.bench_function("info_key_hash", |b| {
        let buckets = [34u32, 29, 78, 3];
        b.iter(|| rbm_mccfr::info_key::make_info_key(&buckets, 2, b"cc/kk/kh"))
    });
}

fn bench_canonical_hand_id(c: &mut Criterion) {
    c.bench_function("canonical_hand_id", |b| {
        b.iter(|| {
            let mut sum = 0usize;
            for c1 in 0..52u8 {
                for c2 in (c1 + 1)..52u8 {
                    sum += buckets::canonical_hand_id(c1, c2);
                }
            }
            sum
        })
    });
}

fn bench_hand_score(c: &mut Criterion) {
    let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
    let deals: Vec<_> = (0..100).map(|_| card::sample_deal(&mut rng)).collect();

    c.bench_function("hand_score_river_100", |b| {
        b.iter(|| {
            let mut sum = 0.0f64;
            for (p1, _p2, board) in &deals {
                sum += buckets::hand_score(p1, &board[..5]);
            }
            sum
        })
    });
}

fn bench_evaluate7(c: &mut Criterion) {
    let mut rng = Xoshiro256PlusPlus::seed_from_u64(42);
    let deals: Vec<_> = (0..100).map(|_| card::sample_deal(&mut rng)).collect();

    c.bench_function("evaluate7_fast_100", |b| {
        b.iter(|| {
            let mut sum = 0u32;
            for (p1, _p2, board) in &deals {
                let mut h = [0u8; 7];
                h[0] = p1[0];
                h[1] = p1[1];
                h[2..7].copy_from_slice(board);
                sum = sum.wrapping_add(rbm_mccfr::hand_eval_fast::evaluate7_fast(&h));
            }
            sum
        })
    });

    c.bench_function("evaluate7_old_100", |b| {
        b.iter(|| {
            let mut sum = 0u32;
            for (p1, _p2, board) in &deals {
                let mut h = [0u8; 7];
                h[0] = p1[0];
                h[1] = p1[1];
                h[2..7].copy_from_slice(board);
                sum = sum.wrapping_add(rbm_mccfr::hand_eval::evaluate7(&h));
            }
            sum
        })
    });
}

fn bench_1000_iters(c: &mut Criterion) {
    let config = GameConfig::slumbot();
    let n_buckets = 50u32;
    let mut assignments = [0i32; 169];
    for (i, a) in assignments.iter_mut().enumerate() {
        *a = ((i as u32 * n_buckets) / 169).min(n_buckets - 1) as i32;
    }

    c.bench_function("mccfr_1000_iters", |b| {
        b.iter(|| {
            let mut rng = Xoshiro256PlusPlus::seed_from_u64(0xDEAD);
            let mut cfr_states = [CfrState::new(10_000), CfrState::new(10_000)];

            for iter in 0..1000u64 {
                let (p1, p2, board) = card::sample_deal(&mut rng);
                let p1_buckets =
                    buckets::precompute_buckets(&p1, &board, n_buckets, &assignments);
                let p2_buckets =
                    buckets::precompute_buckets(&p2, &board, n_buckets, &assignments);

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

                traversal::mccfr_traverse(
                    &config,
                    &p1,
                    &p2,
                    &board,
                    &p1_buckets,
                    &p2_buckets,
                    &mut history,
                    state,
                    traverser,
                    &mut cfr_states,
                    &mut rng,
                    0,
                    f32::INFINITY,
                    0,
                    None,
                );
            }
            cfr_states[0].len() + cfr_states[1].len()
        })
    });
}

criterion_group!(benches, bench_info_key_hash, bench_canonical_hand_id, bench_hand_score, bench_evaluate7, bench_1000_iters);
criterion_main!(benches);
