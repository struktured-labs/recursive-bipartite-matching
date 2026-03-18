# Cloud Training Live Report

Last updated: 2026-03-18 14:00 UTC

## Active Instances

| Instance | Type | RAM | Config | Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|--------|----------|-----------|----------|----------|
| i-0100d83e1c0fe8ffb | r6i.4xlarge | 128GB | 100b@30M | ~20M/30M (67%) | ~150M | 64GB ✓ | - (saving) |
| i-083c08f360f4b51bb | r6i.8xlarge | 256GB | 169b@30M | 23.97M/30M (80%) | **219.8M** | 149GB ✓ | 0.40 |

## Historical Results (Slumbot, 1000 hands each)

| Config | Training | bb/hand vs Slumbot | Info Sets | Cost |
|--------|---------|-------------------|-----------|------|
| 20b | 500K (local) | -2.48 | 9M | free |
| 20b | 10M (cloud) | -1.99 | 40M | ~$5 |
| 50b | 15M (cloud) | **-1.37** | 88M | ~$5 |
| 100b | 30M (running) | ??? | ~150M | ~$10 |
| 169b | 30M (running) | ??? | **220M** | ~$20 |

## 169b at 80%! ~60 min to Slumbot result.

## Total AWS Spend: ~$70 estimated
