# Cloud Training Live Report

Last updated: 2026-03-20 14:35 UTC

## ALL PARALLEL ATTEMPTS FAILED — Need different approach

4-worker parallel on r6i.12xlarge (384GB) OOM'd at 81.5% (114M/140M iters).
Each worker independently discovers ~245M info sets (~80GB each).
4 × 80GB + 90GB base = ~410GB needed > 371GB available.

### Options going forward
1. **Single-threaded + streaming checkpoints** — reliable, ~18hr, ~$55
2. **2 workers** on r6i.12xlarge — 2×80GB + 90GB = 250GB, fits. ~2x speedup, ~9hr
3. **4 workers** on r6i.24xlarge (768GB, ~$6/hr) — ~$42 for 7hr, guaranteed fit
4. **Distributed**: 4 separate instances each training independently, merge at end

## Statistically Significant Slumbot Results

| Run | Iters | bb/hand | 95% CI | σ | Hands | Sig? |
|-----|-------|---------|--------|---|-------|------|
| 60M (run 1) | 60M | **-1.28** | **[-1.59, -0.96]** | 25.43 | 25000 | **YES** |
| 60M (run 2) | 60M | **-1.45** | **[-1.76, -1.14]** | 24.75 | 25000 | **YES** |

Weighted average: ~-1.37 bb/hand. True performance is solidly in [-1.6, -1.0] range.

## Instance History

| Instance | Workers | RAM | Fate | Got To |
|---|---|---|---|---|
| i-0f3cbe94c35b0ef68 | 1 | 256GB | OOM at ckpt save | 75M iters |
| i-04b08cd89812cd100 | 1 | 384GB | OOM at ckpt save | 70M iters |
| i-08bffa26c3560a046 | 47 | 384GB | OOM copying state | 60M eval only |
| i-06e8b32002c814369 | 8 | 384GB | OOM (8 workers) | 60M eval only |
| i-031521eaac2cc1762 | 4 | 384GB | OOM (4 workers) | died quickly |
| **i-021a1243d26d4aff0** | **4** | **384GB** | **OOM at 81.5%** | **114M/140M (174M total)** |

## Budget: $500 (spent ~$350, remaining ~$150)
