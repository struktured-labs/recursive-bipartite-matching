# Cloud Training Live Report

Last updated: 2026-03-18 18:30 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Instance | Type | RAM | Total Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|----------------|-----------|----------|----------|
| i-0f3cbe94c35b0ef68 | r6i.8xlarge | 256GB | 33.39M/100M (33%) | 273.6M | 163GB ✓ | -0.53 |

Resume spike settled. Training at ~900 iter/sec.
Next checkpoint: 50M total (~8 hours)
Estimated completion: ~12 hours

## Scaling Curve (Slumbot, 1000+ hands each)

| Config | Training | bb/hand | Info Sets |
|--------|---------|---------|-----------|
| 20b | 500K | -2.48 | 9M |
| 20b | 10M | -1.99 | 40M |
| 50b | 15M | -1.37 | 88M |
| 169b | 25M | **-0.47** | 225M |
| 169b | 100M | ??? (33% done) | 274M+ growing |

## Budget: $500 (spent ~$145, remaining ~$355)
## Auto-scaling: will launch 400M if 100M improves over -0.47
