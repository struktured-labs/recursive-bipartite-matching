# Phase 2 result: PtrHash vs ph::fmph::GOFunction

_2026-06-03. Dev box: AMD Ryzen, DDR4-3200, Linux 6.17. Numbers are
relative — Phase 2 of `docs/MMAP_INDEX_PLAN.md` calls for verification
on the production EPYC 7402P box before committing to PtrHash in Phase 4._

## Setup

- `ptr_hash = 1.1.0` with `PtrHashParams::default()` and the
  `DefaultPtrHash` type alias (FxHash, CubicEps bucket function, Cacheline
  EF compressed values, Vec<u8> storage).
- `ph = 0.8` `fmph::GOFunction::from_slice` — what the trainer already uses.
- Keys: deterministic xoshiro256++ stream of distinct u64s. The
  trainer's own `info_key::make_info_key` also outputs well-mixed u64,
  so the distribution is representative.
- Warm-cache lookups: pre-shuffled probe vector iterated three times
  back-to-back so the MPHF and probe set are L1/L2-resident.

## Quick-summary numbers

| n         | fmph build   | PtrHash build | Build ratio | fmph lookup | PtrHash lookup | Lookup ratio |
|-----------|--------------|---------------|-------------|-------------|----------------|--------------|
| 100 K     | 14 ms        | 8 ms          | 1.8×        | 23 ns/key   | 2.5 ns/key     | **9.5×**     |
| 1 M       | 78 ms        | 19 ms         | 4.1×        | 25 ns/key   | 2.5 ns/key     | **9.7×**     |
| 10 M      | 508 ms       | 90 ms         | 5.6×        | 32 ns/key   | 4.2 ns/key     | **7.6×**     |

Storage: published 2.1 bits/key (fmph) vs 2.4 bits/key (PtrHash). At 1B
entries this is +37.5 MB. At 10B entries +375 MB. **Negligible.**

## Interpretation

PtrHash decisively beats `ph::fmph::GOFunction` on the dimensions we
care about for the LSM-style frozen layers:

- **Lookup speed**: 7-10× faster across all tested sizes. At 10M keys the
  per-lookup latency drops from 32 ns to 4.2 ns. With 32K MCCFR lookups/s
  aggregate this is a real win on training throughput.
- **Build speed**: 4-6× faster. Freeze cycles become noticeably cheaper
  (every 1M iters per thread).
- **Storage cost**: +0.3 bits/key. Verifier was right that PtrHash is
  *bigger* — but the absolute number is trivial.

## Verifier caveats still standing

1. **Real-hardware verification before Phase 4 adoption.** These numbers
   are from a dev box. Production EPYC 7402P + DDR4-3200 ECC may shift
   the ratio (probably not by much; the MPHF code is mostly hash + table
   indexing).
2. **`epserde` mmap dep conflict** is not exercised by these benches.
   Without the `epserde` feature, PtrHash serializes to `Vec<u8>` which we
   can mmap manually via the existing `memmap2`-based `MmapArena`.
   **Decision: do not enable the `epserde` feature** — implement our own
   `Vec<u8>` → mmap path during Phase 4 and avoid pulling in `mmap-rs`.
3. **Construction stability at 1B+ keys.** Not tested here. The fallback
   in `MMAP_INDEX_PLAN.md` (vendor `odht`) still stands if PtrHash misfires
   on a real billion-key freeze.

## Decision

**Adopt PtrHash in Phase 4** (`arc-swap` layer publish), replacing
`ph::fmph::GOFunction` in fresh frozen layers built going forward.
Backward compat path: keep the `ph` dep for loading legacy on-disk layers
that were built with the old MPHF (`load_from_dir` already rebuilds the
MPHF from keys, so the on-disk format is silent about which library was
used; we can rebuild with PtrHash on first load if we want, or keep using
`fmph` for the loader and PtrHash only for freeze writers — Phase 4 will
spec this in detail).

## Reproducing

```bash
cd rust/rbm_mccfr
cargo bench --bench mphf_bench __quick_summary__
```

prints the table above. Full Criterion bench:

```bash
cargo bench --bench mphf_bench mphf_build
cargo bench --bench mphf_bench mphf_lookup
```

The full Criterion runs take ~15-20 min and produce `target/criterion/` HTML
reports.
