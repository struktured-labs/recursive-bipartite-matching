# Cloud Training Live Report

Last updated: 2026-03-18 16:30 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Instance | Type | RAM | Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|----------|-----------|----------|----------|
| i-0f3cbe94c35b0ef68 | r6i.8xlarge | 256GB | 25.49M/100M (25%) | 228.7M | 186GB ✓ | -0.004 🎯 |

Resumed from 25M checkpoint. Training at ~800 iter/sec.
Next checkpoint: 50M total (~7 hours)

## Complete Scaling Curve

| Config | Training | bb/hand | Info Sets | Cost |
|--------|---------|---------|-----------|------|
| 20b | 500K | -2.48 | 9M | free |
| 20b | 10M | -1.99 | 40M | ~$5 |
| 50b | 15M | -1.37 | 88M | ~$5 |
| 169b | 25M | **-0.47** | 225M | ~$20 |
| 169b | 100M (running) | ??? | ~500M est | ~$56 |

## Budget: $500 (spent ~$131, remaining ~$369)
## Auto-scaling: will launch 400M run if 100M shows improvement
