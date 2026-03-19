# Cloud Training Live Report

Last updated: 2026-03-18 20:00 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Total Progress | Info Sets | RAM Used | RAM Free | Avg Util |
|----------------|-----------|----------|----------|----------|
| 38.15M/100M (38%) | 298.1M | 88GB | 156GB ✓ | -0.39 |

Instance: i-0f3cbe94c35b0ef68 | r6i.8xlarge (256GB) | ~900 iter/sec
Next checkpoint: 50M total (~6 hours)

## Scaling Curve

| Config | Training | bb/hand | Info Sets |
|--------|---------|---------|-----------|
| 20b | 500K | -2.48 | 9M |
| 20b | 10M | -1.99 | 40M |
| 50b | 15M | -1.37 | 88M |
| 169b | 25M | **-0.47** | 225M |
| 169b | 100M | ??? (38%) | 298M+ |

Budget: $500 (spent ~$150)
