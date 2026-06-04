# MCCFR Index Architecture Research — 2026-06-03

10-agent fan-out research bundle covering memory-efficient mmap-backed
index designs for billion-scale MCCFR training.

## Why this exists

Current per-thread `FxHashMap` + custom BBHash frozen layers don't fit
into <120 GB working set at the 10B-iter aspirational scale. This research
exhaustively explored Rust libraries, C/C++ bindings, MCCFR prior art,
concurrent hashmap algorithms, mmap design principles, and LSM internals
to inform a redesign.

## Process

1. **Phase 1 (parallel × 6)**: independent deep dives, each ~10-20K tokens
2. **Phase 2 (synthesizer × 1)**: distilled into a single architecture proposal
3. **Phase 3 (adversarial verifiers × 3)**: skeptics tried to break the synthesis

## Files

| File | Content |
|---|---|
| `00_SYNTHESIS.md` | The architecture proposal (build from scratch with PtrHash + arc-swap + LSM layers) |
| `01_research_rust-mmap-libs.md` | odht, fst, redb, sled, rkyv, PtrHash, boomphf evaluations |
| `01_research_cpp-rust-bindings.md` | LMDB/heed, RocksDB, libcuckoo, abseil bindings |
| `01_research_mccfr-prior-art.md` | Libratus / Pluribus / DeepStack / Slumbot data structure choices |
| `01_research_concurrent-hashmap-algos.md` | Swiss tables, Cuckoo, Robin Hood, RCU, MPHF + buffer trade-offs |
| `01_research_mmap-design-principles.md` | Cache lines, hugepages, NUMA, prefetch, MADV hints |
| `01_research_lsm-internals.md` | RocksDB / ScyllaDB / WiscKey / size-tiered vs leveled |
| `02_verify_concurrency-skeptic.md` | Adversarial review of synthesis concurrency claims |
| `02_verify_perf-realism.md` | Verdict-per-claim on performance projections |
| `02_verify_build-reality.md` | Library-existence + effort-estimate honesty check |

## TL;DR after verifier filtering

See `EXECUTIVE_SUMMARY.md` in the parent docs/ directory for the post-verifier
honest assessment. The synthesis is directionally right but has 2 showstoppers
and ~5 significant overclaims that need correction before any code lands.
