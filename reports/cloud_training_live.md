# Cloud Training Live Report

Last updated: 2026-03-19 10:00 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Total Progress | Info Sets | RAM Used | RAM Free | Avg Util | Checkpoints |
|----------------|-----------|----------|----------|----------|-------------|
| **70.86M/100M (71%)** | **432.6M** | 141GB | 104GB ✓ | -0.14 | ✅ 25M, ✅ 50M (27GB) |

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
