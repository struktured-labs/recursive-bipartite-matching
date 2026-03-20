# Cloud Training Live Report

Last updated: 2026-03-20 00:20 UTC

## Instance i-04b08cd89812cd100 — OOM KILLED at 20M checkpoint

Instance: i-04b08cd89812cd100 | r6i.12xlarge (384GB, on-demand)
IP: 98.93.74.244 | Cost: ~$3.02/hr | Runtime: ~8hr

### What happened
- Training reached 20M/50M iterations (70M total, 435M info sets)
- 10M checkpoint (60M total) saved successfully: 31GB, peak 239GB RAM
- 20M checkpoint (70M total) triggered OOM kill: exit code 137
- Serialization spike exceeded 371GB available (steady 156GB + ~160GB buffer)
- 20M checkpoint = 0 bytes (failed). 10M checkpoint = 31GB (valid, on S3)

### Checkpoint RAM progression
| Checkpoint | Steady RAM | Peak RAM | Outcome |
|---|---|---|---|
| 10M (60M total) | 109GB | 239GB | Saved (31GB) |
| 20M (70M total) | 156GB | >371GB | **OOM killed** |

### Key issue: Marshal serialization doesn't scale
OCaml's Marshal.to_channel builds entire serialized form in memory.
As info sets grow, both working set AND serialization buffer grow.
384GB isn't enough for 435M+ info sets.

## Valid Checkpoints on S3

| S3 Key | Size | Total Iters | Info Sets |
|---|---|---|---|
| `169b_100M/checkpoint_25M.dat` | 18.4GB | 25M | 225M |
| `169b_100M/checkpoint_25000000.dat` | 28.9GB | 50M | 353M |
| `169b_200M/checkpoint_10000000.dat` | 31GB | **60M** | **397M** |
| `169b_200M/checkpoint_50M_total.dat` | 28.9GB | 50M (copy) | 353M |

## Slumbot Results

| Config | Training | bb/hand | mbb/hand | Hands | Info Sets |
|--------|---------|---------|----------|-------|-----------|
| 20b | 500K | -2.48 | -2480 | 1000 | 9M |
| 20b | 10M | -1.99 | -1990 | 1000 | 40M |
| 50b | 15M | -1.37 | -1370 | 1000 | 88M |
| 169b | 25M | **-0.47** | -470 | 2000 | 225M |
| 169b | 50M | **-1.16** | -1165 | 2000 | 353M |
| 169b | 60M | pending | — | — | 397M |

## Next Steps
1. Evaluate 60M checkpoint vs Slumbot (use existing instance before it self-terminates)
2. Fix Marshal serialization: stream to disk in chunks, or use Bigarray mmap
3. Or use r6i.24xlarge (768GB, ~$6/hr) for brute-force headroom
4. Consider: is more training actually helping? 50M result (-1165 mbb) was worse than 25M (-470 mbb)

## Budget: $500 (spent ~$285, remaining ~$215)
