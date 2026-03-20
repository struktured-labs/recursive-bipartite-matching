# Experiment Log

## 2026-03-20 06:50 UTC — All Parallel Attempts OOM, Switched to Single-Threaded

**Attempt 1** (16 domains): OOM at 95% (4.75M/5M). 16 × 12M info sets.
**Attempt 2** (4 domains): OOM at ~20% (1M/5M). 29GB at 20% → extrapolated 145GB.
**Attempt 3** (2 domains): Killed at 4%. 8.7GB at 4% → extrapolated 200GB.
**Attempt 4** (single-threaded): Launched. One shared info set table — no
duplication across workers. Est. ~700M info sets × ~100 bytes ≈ 70GB. Fits 123GB.

**Root cause**: Parallel MCCFR duplicates info sets across N independent workers.
Each worker builds its own hash tables. With RBM's fine-grained clustering,
each worker creates ~12M info sets per 300K iters. N workers × M entries = N×M
total memory, not M. Single-threaded shares one table.

**Rule of thumb**: For RBM with 169 buckets on 128GB, use single-threaded.
Parallel RBM needs 256GB+ (for 2 workers) or 768GB (for 4+ workers).

## 2026-03-20 12:15 UTC — 5M RBM RESULT: -1.11 bb/hand! 10M Training Launched

### 5M RBM Slumbot Result (25K hands, STATISTICALLY SIGNIFICANT)
| Metric | Value |
|---|---|
| **Result** | **-1107.56 mbb/hand (-1.11 bb/hand)** |
| **95% CI** | **[-1.43, -0.79] bb/hand** |
| Significant | YES |
| Std dev | 25.86 bb/hand |
| SE | 0.16 bb/hand |
| Info sets | P0=95.9M, P1=151.3M (247M total) |
| Training time | 18,325s (5.1 hr) |
| Checkpoint | checkpoint_5M_5000000.dat (25GB) |

### Comparison: RBM vs Equity
| Method | Iters | bb/hand | 95% CI | Hands |
|---|---|---|---|---|
| Equity 60M | 60M | -1.28 | [-1.59, -0.96] | 25K |
| **RBM 5M** | **5M** | **-1.11** | **[-1.43, -0.79]** | **25K** |

**RBM at 5M iters (-1.11) matches or beats equity at 60M iters (-1.28) with 12x less training.**
CIs overlap, so not a statistically significant difference between the two methods yet.
But the training efficiency is dramatically better — same performance at 1/12th the compute.

### 10M Training Launched
Resuming from 5M checkpoint. Same config (single-threaded, 169b, ε=0.5).
~5 hours to 10M checkpoint + 25K Slumbot eval.

---

## 2026-03-20 05:03 UTC — RBM Cloud Experiment Launched

### Local Smoke Test: PASSED
- **Config**: 50K iters, 169 buckets, RBM ε=0.5, 25K Slumbot hands
- **Result**: -2270.66 mbb/hand (-2.27 bb/hand), 95% CI [-2.77, -1.77]
- **Info sets**: P0=2,562,093 P1=4,394,098 (6.96M total)
- **Status**: Complete. RBM bucketing works end-to-end against real Slumbot.
- Heavily undertrained (50K iters) — result expected to be bad.

### Killed: Equity Cloud Run
- Instance i-031521eaac2cc1762 terminated (was doing equity bucketing, not RBM)
- Only 2.4M/140M iters done (1.7%), no value lost

### Active: RBM Cloud Experiment
- **Instance**: i-0dc922cf7e7d7930d (r6i.4xlarge, 16 vCPU, 128GB, on-demand)
- **IP**: 23.22.131.93
- **Run ID**: rbm-experiment-20260320-010207
- **Config**: 169 buckets, RBM ε=0.5, parallel MCCFR
- **Plan**: 50M total iterations, checkpoint every 5M
- **Eval**: 25K Slumbot hands after each checkpoint (statistically significant)
- **Output**: `scaling_curve.csv` with per-checkpoint bb/hand + 95% CIs
- **Cost**: ~$1.01/hr, estimated ~$25-50 total
- **Status**: Phase 1 (system packages) in progress

### Scaling Curve (will populate as checkpoints complete)
| Checkpoint | Total Iters | bb/hand | 95% CI | Significant? | Info Sets |
|---|---|---|---|---|---|
| **1** | **5M** | **-1.11** | **[-1.43, -0.79]** | **YES** | **247M** |
| 2 | 10M | pending | | | |
| 3 | 15M | pending | | | |
| 4 | 20M | pending | | | |
| 5 | 25M | pending | | | |
| ... | ... | | | | |
| 10 | 50M | pending | | | |

### All Results (with statistical context)
| Run | Bucketing | Iters | bb/hand | 95% CI | Hands | Sig? |
|-----|-----------|-------|---------|--------|-------|------|
| Equity 25M | equity | 25M | -0.47 | ±2.5 (est) | 2000 | NO |
| Equity 50M | equity | 50M | -1.16 | ±1.8 (est) | 2000 | NO |
| Equity 60M | equity | 60M | -1.28 | [-1.59, -0.96] | 25000 | YES |
| **RBM 50K (local)** | **RBM** | **50K** | **-2.27** | **[-2.77, -1.77]** | **25000** | **YES** |
| **RBM 5M (cloud)** | **RBM** | **5M** | **-1.11** | **[-1.43, -0.79]** | **25K** | **YES** |
| RBM 10M (cloud) | RBM | 10M | pending | | 25K | |

### Budget
- Total budget: $600 ($500 original + $100 extra)
- Spent: ~$310 (previous equity runs + terminated equity run)
- Remaining: ~$290
- This experiment: ~$25-50 estimated
