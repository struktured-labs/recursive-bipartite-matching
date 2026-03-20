# Session Log

## 2026-03-19/20: Cloud Training + Performance Overhaul

### Cloud Training Results

**Instance i-0f3cbe94c35b0ef68 (r6i.8xlarge, 256GB, spot)**
- Trained 169b from 25M to 75M total iterations (50M resumed run)
- OOM killed at 75M during checkpoint serialization (Marshal spike to 200GB+)
- 50M total checkpoint saved (28.9GB), 75M checkpoint failed (0 bytes)

**Instance i-04b08cd89812cd100 (r6i.12xlarge, 384GB, on-demand)**
- Evaluated 50M checkpoint vs Slumbot: -1164.93 mbb/hand (2000 hands)
- Resumed training from 50M, reached 70M total (20M into resume)
- 60M checkpoint saved (31GB, peak RAM 239GB during serialization)
- OOM killed at 70M during 20M checkpoint serialization (peak > 371GB)
- Training exit code 137 (SIGKILL from OOM killer)

### Decision: OxCaml vs Flambda2 vs Vanilla OCaml

**Chose: Vanilla OCaml 5.4.0 + `-O2` optimization flags**

Rationale:
- OxCaml IS flambda2 (rebranded as "flambda-backend" → "OxCaml")
- OxCaml is based on OCaml **5.2.0**, our project uses **5.4.0**
- Downgrading risks breakage, loses 2 minor versions of upstream fixes
- OxCaml makes "no promises of stability or backwards compatibility" for extensions
- We don't use OxCaml-specific extensions (unboxed types, layouts, SIMD)
- The `-O2` flag on vanilla compiler gives free gains with zero risk
- Our bottleneck is algorithmic (single-threaded MCCFR), not compiler optimization
- If OxCaml rebases onto 5.4+, reconsider then

### Decision: Hungarian Algorithm

**Chose: Keep current O(n³) implementation**

Rationale:
- Branching factors are tiny: 2-3 children per betting node, ~10 for showdown distributions
- Hungarian on 3×3 = 27 operations — already negligible
- Replacing with Jonker-Volgenant would save < 0.03% of total clustering time
- Hungarian is NOT on the MCCFR training hot path at all
- The actual bottleneck is tree traversal, not matching
- 55 unit tests now cover correctness (20 Hungarian, 21 Distance, 14 Merge)

### Implementations Completed

1. **Streaming checkpoint serialization** (compact_cfr.ml)
   - New chunked binary format `RBMCFR01` — writes entries one at a time
   - Eliminates 2x memory spike from Marshal.to_channel
   - Auto-detects old Marshal format on load (backward compatible)
   - 8 round-trip tests covering both formats
   - `--format chunked|marshal` flag in train_mccfr_nl

2. **Parallel MCCFR training** (compact_cfr.ml)
   - `train_mccfr_parallel` using Domainslib.Task.parallel_for
   - Each domain gets independent cfr_state copy (no locks, no shared mutable state)
   - Post-parallel merge by summing regret_sum + strategy_sum (additive property of MCCFR)
   - Supports resume, checkpointing, progress reporting via Atomic counters
   - Expected 4-8x speedup on multicore instances

3. **Hot-path key construction optimization** (compact_cfr.ml)
   - Replaced Buffer + Int.to_string with direct byte writing (zero intermediate allocations)
   - Replaced Hashtbl.find + Hashtbl.set with find_or_add (single lookup)
   - Output format identical — checkpoint compatibility preserved
   - All tests pass

4. **Compiler optimization flags** (dune-workspace)
   - Added `-O2` for both dev and release profiles
   - Clean build + all tests pass

5. **Statistical CI reporting** (slumbot_client.ml)
   - Tracks per-hand winnings, computes σ, SE, 95% CI
   - Reports significance (YES/NO based on CI including zero)
   - Reports minimum hands needed for ±0.5 bb/hand CI
   - `--min-hands` flag warns if sample too small

6. **Unit test suite** (test/)
   - 55 inline tests: 20 Hungarian, 21 Distance, 14 Merge
   - Plus 8 checkpoint round-trip tests
   - All passing

7. **Paper statistical notes** (docs/paper.tex, WRITEUP.md)
   - Added CIs and "(n.s.)" to all 3 MCCFR head-to-head claims
   - Limit Hold'em +0.02: CI [-0.19, +0.23], not significant
   - NL 20bb -0.12: CI [-0.26, +0.02], not significant
   - NL 200bb -1.05: strengthened "not statistically reliable" caveat
   - Abstraction quality comparisons (5-0, 7-0) untouched — exact computations

### Statistical Significance Standards (going forward)

- **Minimum**: 1000 hands with CI reporting (2 min, free)
- **Publication**: 25,000 hands for ±0.5 bb/hand CI (44 min, ~$2)
- **High confidence**: 100,000 hands for ±0.25 bb/hand CI (3 hr, ~$9)
- All future experiments MUST report 95% CI
- Slumbot client now computes these automatically

### Performance Optimization Priority (not yet implemented)

| Optimization | Est. Impact | Status |
|---|---|---|
| Parallel MCCFR (multicore) | 4-8x | **Done** |
| `-O2` compiler flags | 10-15% | **Done** |
| Zero-alloc key construction | 10-20% | **Done** |
| find_or_add in hot path | 5-8% | **Done** |
| Bigarray for regret tables | 8-12% | Future |
| Int64 keys (replace strings) | 10-20% | Future (needs collision analysis) |

### Budget

| Item | Cost |
|---|---|
| Previous runs (20b-169b, various) | ~$200 |
| 169b 100M run (terminated at 75M) | ~$70 |
| Resume run (terminated at 70M) | ~$25 |
| **Total spent** | **~$295** |
| **Budget remaining** | **~$205 of $500** |
