# Cloud Training Live Report

Last updated: 2026-03-20 02:50 UTC

## Active: Parallel Run (169b, 60M→200M)

Instance: i-08bffa26c3560a046 | r6i.12xlarge (48 vCPU, 384GB, on-demand)
IP: 3.85.87.157 | Cost: ~$3.02/hr

| Phase | Status | Notes |
|-------|--------|-------|
| Setup (OCaml 5.2) | Done (~3.5 min) | |
| Download 60M ckpt | Done (31GB) | |
| **60M Slumbot eval** | **Done (25K hands)** | **-1275.55 mbb/hand, 95% CI [-1.59, -0.96] bb/hand** |
| **Parallel training** | **In Progress** | 140M iters on 48 cores, chunked checkpoints |
| 200M Slumbot eval | Pending | 25K hands after training |

### 60M Eval — First Statistically Significant Result!

| Metric | Value |
|---|---|
| Result | -1275.55 mbb/hand (-1.28 bb/hand) |
| Std dev | 25.43 bb/hand |
| Std error | 0.16 bb/hand |
| 95% CI | **[-1.59, -0.96] bb/hand** |
| Significant | **YES** (CI excludes zero) |
| Hands | 25,000 |

## Slumbot Results (with statistical context)

| Config | Iters | bb/hand | 95% CI | Hands | Significant? |
|--------|-------|---------|--------|-------|---|
| 20b | 500K | -2.48 | ±2.5 (est) | 1000 | NO |
| 20b | 10M | -1.99 | ±2.5 (est) | 1000 | NO |
| 50b | 15M | -1.37 | ±2.5 (est) | 1000 | NO |
| 169b | 25M | -0.47 | ±2.5 (est) | 2000 | NO |
| 169b | 50M | -1.16 | ±1.8 (est) | 2000 | NO |
| **169b** | **60M** | **-1.28** | **[-1.59, -0.96]** | **25000** | **YES** |

Note: Prior results with <2000 hands had σ≈25-40 bb/hand, making CIs ±2-3 bb/hand.
The 25K hand eval at 60M is the first result we can trust. Earlier "better" results (-0.47)
were noise — the 25K result proves the true performance is around -1.28 bb/hand.

## Improvements This Run

1. **Streaming checkpoints** — chunked binary format, no Marshal OOM
2. **Parallel MCCFR** — 48 cores via Domainslib
3. **25K Slumbot hands** — statistically significant (±0.5 bb/hand CI)
4. **CI reporting** — σ, SE, 95% CI computed automatically

## Budget: $500 (spent ~$300, remaining ~$200)
