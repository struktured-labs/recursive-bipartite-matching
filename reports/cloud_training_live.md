# Cloud Training Live Report

Last updated: $(date -u)

## Active Instances

| Instance | Type | RAM | Config | Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|--------|----------|-----------|----------|----------|
| i-0100d83e1c0fe8ffb | r6i.4xlarge | 128GB | 100b@30M | 14.39M/30M (48%) | 124.6M | 72GB | 0.09 |
| i-083c08f360f4b51bb | r6i.8xlarge | 256GB | 169b@30M | 17.05M/30M (57%) | 180.1M | 173GB | 0.27 |

## Historical Results

| Config | Training | bb/hand vs Slumbot | Info Sets | Avg Util | Cost |
|--------|---------|-------------------|-----------|----------|------|
| 20b | 500K (local) | -2.48 | 9M | ~1.0 | free |
| 20b | 10M (cloud) | **-1.99** | 40M | 0.32 | ~$5 |
| 50b | 15M (cloud) | **-1.37** | 88M | 0.02 | ~$5 |
| 100b | 30M (running) | ??? | 124M+ | 0.09 | ~$10 |
| 169b | 30M (running) | ??? | 180M+ | 0.27 | ~$20 |

## Key Findings

1. **More buckets > more training**: 20b/10M→50b/15M gained 0.62 bb/h, vs 20b/500K→20b/10M gained only 0.49
2. **Convergence**: avg_util oscillates around zero with decreasing amplitude
3. **Memory scaling**: ~0.35GB per 1M info sets with compact storage
4. **The 256GB instance was essential**: 169b creates 180M+ info sets

## Checkpoints on S3

```
s3://rbm-training-results-325614625768/
├── checkpoints/          (20b: 5M, 10M)
├── checkpoints_50b/      (50b: 5M, 10M, 15M)
├── checkpoints_100b_30M/ (pending upload)
├── checkpoints_169b_30M/ (169b: 5M, 10M, 15M)
└── results/
```

## Total AWS Spend: ~$50 estimated
