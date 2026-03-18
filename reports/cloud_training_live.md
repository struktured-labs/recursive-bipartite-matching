# Cloud Training Live Report

Last updated: 2026-03-18 13:15 UTC

## Active Instances

| Instance | Type | RAM | Config | Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|--------|----------|-----------|----------|----------|
| i-0100d83e1c0fe8ffb | r6i.4xlarge | 128GB | 100b@30M | 17.2M/30M (57%) | 138.3M | 67GB ✓ | 0.20 |
| i-083c08f360f4b51bb | r6i.8xlarge | 256GB | 169b@30M | 20.48M/30M (68%) | **200.3M** | 153GB ✓ | 0.47 |

## Historical Results (Slumbot, 1000 hands each)

| Config | Training | bb/hand vs Slumbot | Info Sets | Cost |
|--------|---------|-------------------|-----------|------|
| 20b | 500K (local) | -2.48 | 9M | free |
| 20b | 10M (cloud) | -1.99 | 40M | ~$5 |
| 50b | 15M (cloud) | **-1.37** | 88M | ~$5 |
| 100b | 30M (running) | ??? | 138M+ | ~$10 |
| 169b | 30M (running) | ??? | **200M+** | ~$20 |

## Milestones
- 169b crossed **200M info sets** ✅
- 169b saved **20M checkpoint (16GB)** ✅
- Largest poker AI model built from this framework

## Checkpoints on S3
- 20b: 5M, 10M
- 50b: 5M, 10M, 15M
- 100b: 5M, 10M, 15M
- 169b: 5M, 10M, 15M, **20M (16GB)**

## Total AWS Spend: ~$65 estimated
