# Cloud Training Live Report

Last updated: 2026-03-20 03:15 UTC

## NO ACTIVE INSTANCES — All terminated

## First Statistically Significant Slumbot Result

| Metric | Value |
|---|---|
| Checkpoint | 60M total iterations, 169 buckets |
| Result | **-1275.55 mbb/hand (-1.28 bb/hand)** |
| Std dev | 25.43 bb/hand |
| Std error | 0.16 bb/hand |
| 95% CI | **[-1.59, -0.96] bb/hand** |
| Significant | **YES** (CI excludes zero) |
| Hands | 25,000 |
| Info sets | P0=179.6M, P1=217.7M (397M total) |

## All Slumbot Results (with statistical context)

| Config | Iters | bb/hand | 95% CI | Hands | Significant? |
|--------|-------|---------|--------|-------|---|
| 20b | 500K | -2.48 | ±2.5 (est) | 1000 | NO |
| 20b | 10M | -1.99 | ±2.5 (est) | 1000 | NO |
| 50b | 15M | -1.37 | ±2.5 (est) | 1000 | NO |
| 169b | 25M | -0.47 | ±2.5 (est) | 2000 | NO |
| 169b | 50M | -1.16 | ±1.8 (est) | 2000 | NO |
| **169b** | **60M** | **-1.28** | **[-1.59, -0.96]** | **25000** | **YES** |

Prior results with ≤2000 hands were noise (σ≈25 bb/hand → CI ±2-3 bb/hand).
The -0.47 at 25M was NOT better — it was just lucky variance.

## Checkpoint Inventory on S3

Bucket: `rbm-training-results-325614625768`

| S3 Path | Size | Total Iters | Info Sets | Format |
|---|---|---|---|---|
| `checkpoints_169b_30M/checkpoint_25000000.dat` | 18.4GB | 25M | 225M | Marshal |
| `checkpoints_169b_100M/checkpoint_25000000.dat` | 28.9GB | 50M | 353M | Marshal |
| `checkpoints_169b_200M/checkpoint_10000000.dat` | 31GB | **60M** | **397M** | Marshal |
| `checkpoints_169b_parallel/checkpoint_60M_total.dat` | 31GB | 60M (copy) | 397M | Marshal |

All checkpoints are in old Marshal format. New chunked format (`RBMCFR01`) is
implemented but hasn't been used for cloud saves yet. `load_checkpoint` auto-detects both.

## What Needs To Happen Next

### IMMEDIATE: Resume training from 60M → 200M+
1. Launch r6i.12xlarge (384GB, on-demand)
2. Download 60M checkpoint from `checkpoints_169b_200M/checkpoint_10000000.dat`
3. Use `--parallel --resume checkpoint.dat --train 140000000 --checkpoint-every 25000000`
4. Use `--hands 25000` for statistically significant Slumbot eval after training
5. **Debug why last instance terminated before training started**
   - Check if setup script has an error path that triggers self-termination
   - The eval completed fine (exit 0), so it's a Phase 7 startup issue
6. Script: `scripts/cloud/setup_parallel_169b.sh` (already written, needs debugging)

### PAPER: Cepheus comparison
- Cepheus server alive at `poker.srv.ualberta.ca` (unmaintained since 2022)
- Strategy query API: `GET /query?queryString={betting}:{cards}`
- Very slow/degraded (60s timeout returned nothing)
- If it responds: query ~50 canonical preflop hands, compare RBM vs EMD strategy
  distances to Cepheus's ε-Nash as ground truth
- open-pure-cfr (Alberta, GitHub) is another comparison target for limit hold'em

### PAPER: Statistical cleanup
- Paper stats notes already added (all 3 MCCFR h2h marked n.s.)
- Abstraction quality comparisons (5-0, 7-0) are exact — fine as-is
- Need to re-run MCCFR h2h tournaments with 25K+ hands for publication

### Performance optimizations implemented but untested on cloud
- Streaming checkpoints (RBMCFR01) — eliminates OOM during save
- Parallel MCCFR — 4-8x on multicore
- Zero-alloc key construction — 10-20% fewer allocations
- -O2 compiler flags — 10-15% improvement

## Instance History

| Instance | Type | RAM | Fate | Got To |
|---|---|---|---|---|
| i-0f3cbe94c35b0ef68 | r6i.8xlarge | 256GB | OOM at 75M ckpt save | 75M iters |
| i-0e75c49991ea93bfc | r6i.12xlarge | 384GB | Bootstrap fail (no awscli) | — |
| i-04b08cd89812cd100 | r6i.12xlarge | 384GB | OOM at 70M ckpt save | 70M iters |
| i-08bffa26c3560a046 | r6i.12xlarge | 384GB | Terminated after eval | 60M eval only |

## AWS Details

- Account: 325614625768, region us-east-1
- SSH key: `~/.ssh/rbm-training.pem`
- S3 bucket: `rbm-training-results-325614625768`
- IAM role: `rbm-training-role`, profile: `rbm-training-profile`
- Security group: `rbm-ssh` (SSH from anywhere)
- AMI: `ami-0ec10929233384c7f` (Ubuntu 24.04 Noble)

## Budget: $500 (spent ~$305, remaining ~$195)
