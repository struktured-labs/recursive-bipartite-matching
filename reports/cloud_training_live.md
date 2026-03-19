# Cloud Training Live Report

Last updated: 2026-03-19 08:15 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Total Progress | Info Sets | RAM Used | RAM Free | Avg Util | Checkpoints |
|----------------|-----------|----------|----------|----------|-------------|
| **66.44M/100M (66%)** | **417.2M** | 135GB | 110GB ✓ | -0.22 | ✅ 25M, ✅ 50M (27GB) |

Instance: i-0f3cbe94c35b0ef68 | r6i.8xlarge (256GB) | ~900 iter/sec
HALFWAY! Next checkpoint: 75M total (~7 hours)

## Scaling Curve

| Config | Training | bb/hand | Info Sets |
|--------|---------|---------|-----------|
| 20b | 500K | -2.48 | 9M |
| 20b | 10M | -1.99 | 40M |
| 50b | 15M | -1.37 | 88M |
| 169b | 25M | **-0.47** | 225M |
| 169b | 100M | ??? (62%) | **401M+** |

## Budget: $500 (spent ~$170, remaining ~$330)
