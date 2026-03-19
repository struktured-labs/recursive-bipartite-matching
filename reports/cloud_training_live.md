# Cloud Training Live Report

Last updated: 2026-03-19 11:45 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Total Progress | Info Sets | RAM Used | RAM Free | Avg Util | Checkpoints |
|----------------|-----------|----------|----------|----------|-------------|
| **75M/100M (75%)** | **446.4M** | 200GB (checkpoint spike) | 44GB | -0.13 | ✅ 25M, ✅ 50M, **⏳ 75M saving!** |

Instance: i-0f3cbe94c35b0ef68 | r6i.8xlarge (256GB)
3/4 of the way to 100M! Checkpoint serialization in progress.

## Scaling Curve

| Config | Training | bb/hand | Info Sets |
|--------|---------|---------|-----------|
| 20b | 500K | -2.48 | 9M |
| 20b | 10M | -1.99 | 40M |
| 50b | 15M | -1.37 | 88M |
| 169b | 25M | **-0.47** | 225M |
| 169b | 100M | ??? (75%) | **446M+** |

## Budget: $500 (spent ~$200, remaining ~$300)
