# Cloud Training Live Report

Last updated: 2026-03-18 12:30 UTC

## Active Instances

| Instance | Type | RAM | Config | Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|--------|----------|-----------|----------|----------|
| i-0100d83e1c0fe8ffb | r6i.4xlarge | 128GB | 100b@30M | ~15M/30M (50%) | ~125M | 16GB (checkpoint spike) | - |
| i-083c08f360f4b51bb | r6i.8xlarge | 256GB | 169b@30M | 17.99M/30M (60%) | 185.6M | 172GB | 0.48 |

## Historical Results (Slumbot, 1000 hands each)

| Config | Training | bb/hand vs Slumbot | Info Sets | Cost |
|--------|---------|-------------------|-----------|------|
| 20b | 500K (local) | -2.48 | 9M | free |
| 20b | 10M (cloud) | **-1.99** | 40M | ~$5 |
| 50b | 15M (cloud) | **-1.37** | 88M | ~$5 |
| 100b | 30M (running) | ??? | 125M+ | ~$10 |
| 169b | 30M (running) | ??? | 186M+ | ~$20 |

## Trend: More buckets = better play

```
20b/500K:  -2.48 bb/h  ████████████████████████░
20b/10M:   -1.99 bb/h  ████████████████████░░░░░
50b/15M:   -1.37 bb/h  █████████████░░░░░░░░░░░░
100b/30M:  ???
169b/30M:  ???
```

## Checkpoints on S3

- 20b: 5M, 10M
- 50b: 5M, 10M, 15M
- 100b: 5M, 10M, 15M (saving)
- 169b: 5M, 10M, 15M

## Total AWS Spend: ~$55 estimated
