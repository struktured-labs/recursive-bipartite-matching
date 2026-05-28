# 100M parallel-RBM run — Slumbot eval result

**Date:** 2026-05-14 (CEST)
**Branch:** `fix/parallel-rbm-cluster-merge` ([PR #3](https://github.com/struktured-labs/recursive-bipartite-matching/pull/3))
**Hardware:** Hostkey EPYC 9354, 32-core / 64-thread, 755 GB RAM
**Run dir:** `/root/run_100M_t32_eps35_parallel_rbm/` (Hostkey)
**Full log:** `results/run_100M_t32_eps35_parallel_rbm.log` (this repo)

## Headline

**-1.4135 bb/hand, 95% CI [-1.76, -1.07]** over 25,000 Slumbot hands. Statistically significant (CI excludes zero).

This is the first clean parallel-RBM eval after PR #3 lifted the silent-empty-PostflopState bug.

## Configuration

| Setting          | Value          |
|------------------|----------------|
| Iterations       | 100,000,000    |
| Threads          | 32             |
| Bucket method    | RBM            |
| RBM epsilon      | 35.0           |
| Phase 1 iters    | 5,000,000 (cap)|
| Freeze cadence   | 1M iters       |
| Mmap arenas      | yes            |
| DCFR / LCFR      | off / off      |

## Training stats

| Metric                  | Value                              |
|-------------------------|------------------------------------|
| Phase 1 duration        | 12,714.6 s (3.5 h, single-thread) |
| Phase 1 info sets       | P0=41.6M, P1=38.9M                |
| Phase 1 cluster set     | **22 + 23 = 45 clusters**         |
| Total training wall     | 46,626.5 s (13.0 h)               |
| Aggregate speed         | 2,145 iter/sec                    |
| Final info sets         | P0=216.3M, P1=227.9M (444M total) |
| Final memory            | 19.2 GB (regret 4.5 + strat 4.5 + index 10.2) |

Threads-alive: 32/32 (no panics, no watchdog timeouts). 256 freeze + checkpoint events logged, all clean.

## Slumbot eval (25,000 hands, 17,575.8 s wall)

| Metric             | Value                          |
|--------------------|--------------------------------|
| **Average**        | **-1.4135 bb/hand (-1,413.55 mbb/hand)** |
| **95% CI**         | **[-1.76, -1.07] bb/hand**     |
| Std dev            | 27.78 bb/hand                  |
| Std error          | 0.18 bb/hand                   |
| Significant?       | YES (CI excludes zero)         |
| Hands for ±0.5 bb/h CI | 11,855                     |

## Why this matters

Pre-fix (silent-empty-PostflopState bug):

- Parallel RBM training returned an empty cluster set, so every postflop hand fell through to bucket 0.
- The strategy table never trained postflop responses against any real cluster set.
- Prior Rust empirical floor: -2.0 to -2.6 bb/hand across 7+ configurations (`project_compute_floor_confirmed.md`).
- Best clean Rust MCCFR-RBM Slumbot eval before this fix: -2.32 [-2.84, -1.79] at 23M iters (`project_eval_2026_04_24.md`).

Post-fix (this run):

- Phase 1 single-thread discovers 45 clusters; phase 2 shares them read-only across 32 threads via `Arc<PostflopState>`.
- Result jumps from the -2.0 to -2.6 band to **-1.41 [-1.76, -1.07]**.
- Statistically equivalent to the OCaml reference (-1.35 [-1.68, -1.03]) the gap-chasing sessions had been trying to close (`project_ocaml_gap_confirmed.md`).
- ~1 bb/hand of "structural gap" that prior sessions had attributed to unknown bias was actually being eaten by this one parallel-RBM bug.

## Next

`run_250M_t32_eps35_parallel_rbm` started running immediately after; `run_1B_t32_eps35_parallel_rbm` queued. The chainer is `nohup`'d under PID 1 on Hostkey, so it survives Claude session restarts. Each subsequent run auto-Slumbot-evaluates via `--play 25000`.
