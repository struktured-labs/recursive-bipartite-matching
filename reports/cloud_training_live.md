# Cloud Training Live Report

Last updated: 2026-03-19 16:47 UTC

## Active: Resume Run (169b, 50M→100M)

Instance: i-04b08cd89812cd100 | r6i.12xlarge (384GB, on-demand)
IP: 98.93.74.244 | Cost: ~$3.02/hr

| Phase | Status | Notes |
|-------|--------|-------|
| Setup (OCaml 5.2) | Done (3.5 min) | |
| Download 50M ckpt | Done (102s, 26.9GB) | |
| **50M Slumbot eval** | **Done** | **-1164.93 mbb/hand (-1.16 bb/hand)** |
| Resume training | **In Progress** | 370K/50M (0.7%), avg_util=5.1, 95GB RAM |
| 100M Slumbot eval | Pending | After training completes |

## Previous Instance (TERMINATED)

Instance i-0f3cbe94c35b0ef68 died at 75M total iterations during checkpoint save.
75M checkpoint = 0 bytes (failed). 50M checkpoint = 28.9GB (valid, used for resume).

## Slumbot Results

| Config | Training | bb/hand | mbb/hand | Hands | Info Sets |
|--------|---------|---------|----------|-------|-----------|
| 20b | 500K | -2.48 | -2480 | 1000 | 9M |
| 20b | 10M | -1.99 | -1990 | 1000 | 40M |
| 50b | 15M | -1.37 | -1370 | 1000 | 88M |
| 169b | 25M | **-0.47** | -470 | 2000 | 225M |
| 169b | 50M | **-1.16** | -1165 | 2000 | 353M |
| 169b | 100M | ??? | — | 2000 | ~500M est |

Note: 50M result worse than 25M likely due to high variance (SE ≈ 0.9 bb/hand with 200bb stacks).
95% CIs overlap. Need 10K+ hands for reliable comparison.

## Budget: $500 (spent ~$260, remaining ~$240)
