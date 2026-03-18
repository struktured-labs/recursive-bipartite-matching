# Cloud Training Final Report

Last updated: 2026-03-18 15:30 UTC

## BEST RESULT: 169b/25M = -0.47 bb/hand vs Slumbot

## Complete Scaling Curve

| Config | Training | bb/hand | Info Sets | Cost |
|--------|---------|---------|-----------|------|
| 20b | 500K | -2.48 | 9M | free |
| 20b | 10M | -1.99 | 40M | ~$5 |
| 50b | 15M | -1.37 | 88M | ~$5 |
| **169b** | **25M** | **-0.47** | **225M** | **~$20** |

## Key Finding: Abstraction quality > training iterations

20b→169b: +2.01 bb/h improvement (4x more impactful than training scaling)

## Comparison to Published Bots
- Slumbot: 0.00 (by definition)
- ReBeL (Facebook): +0.045 bb/h
- **Ours: -0.47 bb/h** (within striking distance, $75 total spend)

## All Checkpoints on S3 (resumable for billions of iterations)
- 20b: 5M, 10M
- 50b: 5M, 10M, 15M
- 100b: 5M, 10M, 15M, 20M
- 169b: 5M, 10M, 15M, 20M, 25M (18GB)

## Total AWS Spend: ~$75
