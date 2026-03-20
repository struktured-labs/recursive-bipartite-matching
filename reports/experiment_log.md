# Experiment Log

## 2026-03-20 00:20 UTC — Status Check

### Local Smoke Test: RBM Bucketing vs Slumbot
- **Config**: 50K iters, 169 buckets, RBM ε=0.5, 25K Slumbot hands
- **Progress**: 18,830/25,000 hands (75%)
- **Current result**: -2172 mbb/hand (-2.17 bb/hand)
- **RSS**: 2.2GB
- **Status**: Running, ~6 min to completion
- **Note**: Heavily undertrained (50K iters). Purpose is end-to-end validation, not performance.

### Cloud Instance (other session)
- **Instance**: i-031521eaac2cc1762 (r6i.12xlarge, 384GB)
- **IP**: 54.242.219.144
- **Task**: Equity bucketing, 140M iterations (parallel, 8 domains), resuming from 60M checkpoint
- **Status**: Loading checkpoint (96GB RAM, still deserializing)
- **Bucketing**: equity (NOT RBM)

### Pending: RBM Cloud Experiment
- Cloud script ready: `scripts/cloud/setup_rbm_experiment.sh`
- Plan: 50M iterations with RBM bucketing, checkpoint every 5M, 25K Slumbot hands per checkpoint
- Will launch after smoke test passes
- Budget remaining: ~$295 ($600 total - $305 spent)

### Key Comparison
| Run | Bucketing | Iters | bb/hand | Hands | Significant? |
|-----|-----------|-------|---------|-------|---|
| Equity 25M | equity | 25M | -0.47 | 2000 | NO |
| Equity 50M | equity | 50M | -1.16 | 2000 | NO |
| Equity 60M | equity | 60M | -1.28 | 25000 | YES |
| RBM 50K (local) | **RBM** | 50K | ~-2.17 | 25K | in progress |
| RBM cloud | **RBM** | 5-50M | ? | 25K each | pending |
