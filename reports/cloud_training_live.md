# Cloud Training Live Report

Last updated: 2026-03-20 04:05 UTC

## Active: Parallel Training v2 (i-06e8b32002c814369)

Instance: i-06e8b32002c814369 | r6i.12xlarge (48 vCPU, 384GB, on-demand)
IP: 34.228.170.239 | Cost: ~$3.02/hr

| Phase | Status | Notes |
|-------|--------|-------|
| Setup | Done (~3.5 min) | |
| Download 60M ckpt | Done (30.3GB, 100s) | |
| **60M Slumbot eval** | **Done (25K hands)** | **-1450.33 mbb/hand, CI [-1.76, -1.14]** |
| **Parallel training** | **In Progress** | 47 domains, 140M iters, **77GB RAM** |
| 200M Slumbot eval | Pending | 25K hands after training |

### Parallel fix confirmed working!
- Previous attempt: 328GB RAM (copying 90GB state to 47 workers) → OOM
- This attempt: **77GB RAM** (empty workers + 1 base state) → healthy, 293GB free

### 60M Eval (run 2, confirms prior result)

| Metric | Run 1 | Run 2 |
|---|---|---|
| Result | -1275.55 mbb/hand | **-1450.33 mbb/hand** |
| 95% CI | [-1.59, -0.96] | **[-1.76, -1.14]** |
| σ | 25.43 bb/hand | 24.75 bb/hand |
| Significant | YES | **YES** |

CIs overlap — true value is around -1.3 to -1.4 bb/hand for 60M/169b.

## All Slumbot Results

| Config | Iters | bb/hand | 95% CI | Hands | Sig? |
|--------|-------|---------|--------|-------|---|
| 20b | 500K | -2.48 | ±2.5 (est) | 1000 | NO |
| 20b | 10M | -1.99 | ±2.5 (est) | 1000 | NO |
| 50b | 15M | -1.37 | ±2.5 (est) | 1000 | NO |
| 169b | 25M | -0.47 | ±2.5 (est) | 2000 | NO |
| 169b | 50M | -1.16 | ±1.8 (est) | 2000 | NO |
| **169b** | **60M** | **-1.28** | **[-1.59, -0.96]** | **25000** | **YES** |
| **169b** | **60M** | **-1.45** | **[-1.76, -1.14]** | **25000** | **YES** |

## Instance History

| Instance | Type | RAM | Fate | Got To |
|---|---|---|---|---|
| i-0f3cbe94c35b0ef68 | r6i.8xlarge | 256GB | OOM at 75M ckpt save | 75M iters |
| i-04b08cd89812cd100 | r6i.12xlarge | 384GB | OOM at 70M ckpt save | 70M iters |
| i-08bffa26c3560a046 | r6i.12xlarge | 384GB | OOM (parallel deep-copy) | 60M eval only |
| **i-06e8b32002c814369** | r6i.12xlarge | 384GB | **Running** | **Parallel training** |

## Budget: $500 (spent ~$315, remaining ~$185)
