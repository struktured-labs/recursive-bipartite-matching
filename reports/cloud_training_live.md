# Cloud Training Live Report

Last updated: 2026-03-18 12:45 UTC

## Active Instances

| Instance | Type | RAM | Config | Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|--------|----------|-----------|----------|----------|
| i-0100d83e1c0fe8ffb | r6i.4xlarge | 128GB | 100b@30M | 15.74M/30M (52%) | 131.4M | 68GB ✓ | 0.14 |
| i-083c08f360f4b51bb | r6i.8xlarge | 256GB | 169b@30M | 18.94M/30M (63%) | 191.3M | 171GB ✓ | 0.42 |

## Historical Results (Slumbot, 1000 hands each)

| Config | Training | bb/hand vs Slumbot | Info Sets | Cost |
|--------|---------|-------------------|-----------|------|
| 20b | 500K (local) | -2.48 | 9M | free |
| 20b | 10M (cloud) | -1.99 | 40M | ~$5 |
| 50b | 15M (cloud) | **-1.37** | 88M | ~$5 |
| 100b | 30M (running) | ??? | 131M+ | ~$10 |
| 169b | 30M (running) | ??? | 191M+ | ~$20 |

## Checkpoints on S3

- 20b: 5M, 10M ✅
- 50b: 5M, 10M, 15M ✅
- 100b: 5M, 10M, **15M (9.7GB)** ✅
- 169b: 5M, 10M, 15M ✅

## Total AWS Spend: ~$60 estimated
