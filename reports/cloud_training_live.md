# Cloud Training Live Report

Last updated: 2026-03-18 17:00 UTC

## Active: Breakeven Run (169b, 25M→100M)

| Instance | Type | RAM | Total Progress | Info Sets | RAM Free | Avg Util |
|----------|------|-----|----------------|-----------|----------|----------|
| i-0f3cbe94c35b0ef68 | r6i.8xlarge | 256GB | 27.34M/100M (27%) | 240.2M | 183GB ✓ | 1.52 (settling) |

Next checkpoint: 50M total (~5 hours)

## Scaling Curve (Slumbot, 1000+ hands each)

| Config | Training | bb/hand | Info Sets |
|--------|---------|---------|-----------|
| 20b | 500K | -2.48 | 9M |
| 20b | 10M | -1.99 | 40M |
| 50b | 15M | -1.37 | 88M |
| 169b | 25M | **-0.47** | 225M |
| 169b | 100M | ??? (running) | ~500M est |

## Budget: $500 (spent ~$140, remaining ~$360)
## Will auto-launch 400M if 100M shows improvement
