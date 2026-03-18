# Cloud Training Live Report

Last updated: 2026-03-18 16:00 UTC

## Active Instance: Breakeven Run

| Instance | Type | RAM | Config | Status |
|----------|------|-----|--------|--------|
| i-0f3cbe94c35b0ef68 | r6i.8xlarge | 256GB | 169b resume 25M→100M | Downloading 18GB checkpoint from S3 |

## Target: BREAKEVEN against Slumbot

## Historical Results (Slumbot, 1000 hands each)

| Config | Training | bb/hand | Info Sets | Cost |
|--------|---------|---------|-----------|------|
| 20b | 500K | -2.48 | 9M | free |
| 20b | 10M | -1.99 | 40M | ~$5 |
| 50b | 15M | -1.37 | 88M | ~$5 |
| 169b | 25M | **-0.47** | 225M | ~$20 |
| 169b | 100M (running) | ??? | ~500M est | ~$56 |

## Prediction (O(1/√T) convergence)
- 50M: ~-0.33
- 75M: ~-0.27
- 100M: ~-0.24
- Breakeven needs ~400M+ (resumable from checkpoints)

## Total AWS Spend: ~$130 estimated (including this run)
