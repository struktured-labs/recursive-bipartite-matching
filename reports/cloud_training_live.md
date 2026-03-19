# Cloud Training Live Report

Last updated: 2026-03-19 05:00 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Total Progress | Info Sets | RAM Used | RAM Free | Avg Util | Checkpoints |
|----------------|-----------|----------|----------|----------|-------------|
| **58.22M/100M (58%)** | **386.7M** | 131GB | 113GB ✓ | -0.17 | ✅ 25M, ✅ 50M (27GB) |

Instance: i-0f3cbe94c35b0ef68 | r6i.8xlarge (256GB) | ~900 iter/sec
HALFWAY! Next checkpoint: 75M total (~7 hours)

## Scaling Curve

| Config | Training | bb/hand | Info Sets |
|--------|---------|---------|-----------|
| 20b | 500K | -2.48 | 9M |
| 20b | 10M | -1.99 | 40M |
| 50b | 15M | -1.37 | 88M |
| 169b | 25M | **-0.47** | 225M |
| 169b | 100M | ??? (50% done) | 354M+ |

## Budget: $500 (spent ~$170, remaining ~$330)
