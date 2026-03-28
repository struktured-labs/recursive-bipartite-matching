# Performance Benchmarks & Regression Baselines

All benchmarks on: Intel i9-12900K (24 threads), 125GB RAM, RTX 3090 24GB.

## Iteration Speed (single-threaded, 169 buckets, equity bucketing)

| Date | Config | iter/s | Commit | Notes |
|---|---|---|---|---|
| 2026-03-24 | Vanilla (no DCFR) | 13,260 | 0770eb2 | First Rust benchmark |
| 2026-03-24 | Bulk DCFR (every iter) | 326 | — | BROKEN: O(entries) scan |
| 2026-03-24 | Lazy DCFR + fast eval | 26,671 | 72547c4 | 82x over bulk DCFR |
| 2026-03-24 | Lazy DCFR + fast eval + LCFR | 33,784 | 72547c4 | Best single-threaded |
| 2026-03-24 | 24-thread parallel | 39,923 | 72547c4 | Poor scaling (memory dup) |

**Regression baseline: single-threaded DCFR+LCFR must be ≥25,000 iter/s at 100K iters.**

## Hand Evaluation (100 random 7-card hands)

| Evaluator | Time (100 hands) | Per-hand | Speedup |
|---|---|---|---|
| Old C(7,5) enumeration | 115 µs | 1.15 µs | 1x |
| Fast bitmask | 1.6 µs | 16 ns | **72x** |

**Regression baseline: evaluate7_fast must be ≤2.0 µs per 100 hands.**

## Memory (single-threaded, 5M iters, 169 buckets)

| Date | Storage | RSS at 5M | Info sets | Commit |
|---|---|---|---|---|
| 2026-03-24 | f32 Vec | ~18 GB | 148M | — |
| 2026-03-25 | i16 arena (single) | 10.7 GB | 324M | 47c2931 |
| 2026-03-28 | Split arena (i16+f32) | TBD | TBD | 3039645 |

**Regression baseline: 5M iters must use ≤20 GB RSS.**

## Slumbot Results (25K hands, statistically significant)

| Date | Bucketing | Iters | bb/hand | 95% CI | Storage | Commit |
|---|---|---|---|---|---|---|
| 2026-03-20 | RBM (OCaml) | 5M | **-1.11** | [-1.43, -0.79] | f32 | — |
| 2026-03-21 | RBM (OCaml) | 5M | -1.31 | [-1.64, -0.98] | Int64 | — |
| 2026-03-24 | Equity (Rust) | 5M | -1.16 | [-1.47, -0.85] | f32 | — |
| 2026-03-26 | Equity (Rust) | 25M | -2.43 | [-2.94, -1.91] | i16 (BROKEN) | — |
| 2026-03-28 | Equity (Rust) | 25M | TBD | TBD | split i16+f32 | 3039645 |

**Target: RBM bucketing in Rust at 25M+ iters. Must beat -1.11 bb/hand.**

## How to run benchmarks

```bash
# Iteration speed
cargo bench

# Memory at 5M
/usr/bin/time -v ./target/release/rbm-mccfr --iterations 5000000 --n-buckets 169 --threads 1 --dcfr --lcfr --output /dev/null

# Quick Slumbot smoke test (1K hands, not significant but directional)
./target/release/rbm-mccfr --iterations 5000000 --n-buckets 169 --dcfr --lcfr --output /tmp/bench.bin --play 1000
```
