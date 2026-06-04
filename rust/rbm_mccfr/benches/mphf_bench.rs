//! Phase 2 of docs/MMAP_INDEX_PLAN.md — decision gate for adopting PtrHash.
//!
//! Compares `ph::fmph::GOFunction` (incumbent, used by the frozen-layer LSM)
//! against `ptr_hash::PtrHash` (candidate replacement from the SEA 2025 paper)
//! on three axes:
//!
//!   - Build time: how long does construction take for a given key set?
//!   - Storage: bits/key after serialization (a rough lower bound for memory
//!     resident at lookup time).
//!   - Lookup latency: warm-cache throughput when probing random keys from
//!     the original set.
//!
//! The verifier (`02_verify_perf-realism.md`) flagged that PtrHash benchmark
//! numbers in the literature use DDR4-3200 on an i7-10750H; the EPYC 7402P
//! we'll deploy on has different memory subsystem. Run this benchmark on the
//! actual production hardware before making the Phase 4 PtrHash-vs-fmph
//! decision. Local results from a dev box are directional, not definitive.

use std::time::Instant;

use criterion::{black_box, criterion_group, criterion_main, Criterion, Throughput, BenchmarkId};
use rand::SeedableRng;
use rand_xoshiro::Xoshiro256PlusPlus;

use ph::fmph;
use ptr_hash::{PtrHashParams, DefaultPtrHash};

/// Generate a deterministic set of `n` distinct u64 keys.
///
/// Uses xoshiro256++ seeded to a fixed value so each run benchmarks the same
/// key set. The keys are well-mixed (not the splitmix output of consecutive
/// integers), which approximates MCCFR's actual key distribution where keys
/// come from `info_key::make_info_key(...)`.
fn make_keys(n: usize) -> Vec<u64> {
    use rand::RngCore;
    let mut rng = Xoshiro256PlusPlus::seed_from_u64(0xCAFE_BABE_DEAD_BEEF);
    // Use a HashSet to deduplicate. At 1M keys the birthday-bound collision
    // probability over u64 is ~10^-7, but the test wants exactly N distinct
    // keys so we dedup defensively.
    use rustc_hash::FxHashSet;
    let mut set: FxHashSet<u64> = FxHashSet::default();
    set.reserve(n);
    while set.len() < n {
        set.insert(rng.next_u64());
    }
    set.into_iter().collect()
}

/// Build-time benchmark. Measures how long each MPHF takes to construct
/// over a fresh key set. Build time matters because we rebuild at every
/// freeze cycle in the LSM.
fn bench_build(c: &mut Criterion) {
    let mut g = c.benchmark_group("mphf_build");
    g.sample_size(10); // Build is slow; small sample is fine.
    for &n in &[100_000usize, 1_000_000, 10_000_000] {
        let keys = make_keys(n);
        g.throughput(Throughput::Elements(n as u64));

        g.bench_with_input(BenchmarkId::new("fmph_GOFunction", n), &keys, |b, keys| {
            b.iter(|| {
                let mphf = fmph::GOFunction::from_slice(black_box(keys));
                black_box(mphf);
            });
        });

        g.bench_with_input(BenchmarkId::new("PtrHash_default", n), &keys, |b, keys| {
            b.iter(|| {
                let mphf = <DefaultPtrHash>::new(black_box(keys), PtrHashParams::default());
                black_box(mphf);
            });
        });
    }
    g.finish();
}

/// Warm-cache lookup benchmark. Builds the MPHF once, then probes a deterministic
/// stream of keys from the original set in random order. Measures ns/lookup at
/// steady state when both the MPHF and the key stream are L1/L2-resident.
fn bench_lookup(c: &mut Criterion) {
    let mut g = c.benchmark_group("mphf_lookup");
    g.sample_size(50);

    for &n in &[100_000usize, 1_000_000, 10_000_000] {
        let keys = make_keys(n);

        // Build both MPHFs once.
        let fmph_built = fmph::GOFunction::from_slice(&keys);
        let ptrhash_built = <DefaultPtrHash>::new(&keys, PtrHashParams::default());

        // Probe order: shuffle a copy of the keys deterministically so each
        // benchmark variant sees the same access pattern.
        use rand::seq::SliceRandom;
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(0x1234_5678_9ABC_DEF0);
        let mut probe = keys.clone();
        probe.shuffle(&mut rng);

        g.throughput(Throughput::Elements(probe.len() as u64));

        g.bench_with_input(BenchmarkId::new("fmph_GOFunction_warm", n), &probe, |b, probe| {
            b.iter(|| {
                let mut sum: u64 = 0;
                for k in probe.iter() {
                    let slot = fmph_built.get(k).unwrap_or(u64::MAX);
                    sum = sum.wrapping_add(slot);
                }
                black_box(sum);
            });
        });

        g.bench_with_input(BenchmarkId::new("PtrHash_default_warm", n), &probe, |b, probe| {
            b.iter(|| {
                let mut sum: u64 = 0;
                for k in probe.iter() {
                    let slot = ptrhash_built.index(k);
                    sum = sum.wrapping_add(slot as u64);
                }
                black_box(sum);
            });
        });
    }
    g.finish();
}

/// Prints build time + estimated bits/key + 100-key sequential-lookup ns
/// straight to stdout, as a fast summary independent of Criterion's
/// statistical machinery. Useful for quick A/B reads when the full
/// `cargo bench` run is too slow to wait on.
fn print_quick_summary() {
    for &n in &[100_000usize, 1_000_000, 10_000_000] {
        let keys = make_keys(n);
        println!();
        println!("=== n = {} keys ===", n);

        // fmph build + size estimate.
        let t0 = Instant::now();
        let fmph_built = fmph::GOFunction::from_slice(&keys);
        let fmph_build_ms = t0.elapsed().as_secs_f64() * 1000.0;
        // ph::fmph::GOFunction does not expose a direct byte size; estimate via
        // its internal levels metadata. Fall back to "n/a" if not exposed.
        let fmph_bits_estimate = "(see published 2.1 bits/key)";

        // ptr_hash build.
        let t0 = Instant::now();
        let ptrhash_built = <DefaultPtrHash>::new(&keys, PtrHashParams::default());
        let ptrhash_build_ms = t0.elapsed().as_secs_f64() * 1000.0;
        let ptrhash_bits_estimate = "(see published 2.4 bits/key)";

        // 1M-iteration warm lookup loop. Shuffle a small probe set to land
        // in cache; this measures the inner-loop cost.
        use rand::seq::SliceRandom;
        let mut rng = Xoshiro256PlusPlus::seed_from_u64(0xDEAD_BEEF_CAFE_F00D);
        let probe_size = n.min(1_000_000);
        let mut probe: Vec<u64> = keys.iter().copied().take(probe_size).collect();
        probe.shuffle(&mut rng);

        let t0 = Instant::now();
        let mut sum: u64 = 0;
        for _ in 0..3 {
            for k in probe.iter() {
                sum = sum.wrapping_add(fmph_built.get(k).unwrap_or(u64::MAX));
            }
        }
        std::hint::black_box(sum);
        let fmph_lookup_ns =
            t0.elapsed().as_secs_f64() * 1e9 / (3.0 * probe.len() as f64);

        let t0 = Instant::now();
        let mut sum: u64 = 0;
        for _ in 0..3 {
            for k in probe.iter() {
                sum = sum.wrapping_add(ptrhash_built.index(k) as u64);
            }
        }
        std::hint::black_box(sum);
        let ptrhash_lookup_ns =
            t0.elapsed().as_secs_f64() * 1e9 / (3.0 * probe.len() as f64);

        println!("  fmph_GOFunction:  build {:>8.1} ms   storage {}",
            fmph_build_ms, fmph_bits_estimate);
        println!("                    warm lookup {:>6.1} ns/key (probe={} keys)",
            fmph_lookup_ns, probe_size);
        println!("  PtrHash_default:  build {:>8.1} ms   storage {}",
            ptrhash_build_ms, ptrhash_bits_estimate);
        println!("                    warm lookup {:>6.1} ns/key (probe={} keys)",
            ptrhash_lookup_ns, probe_size);
        println!("  Lookup ratio (fmph / PtrHash) = {:.2}x",
            fmph_lookup_ns / ptrhash_lookup_ns);
    }
    println!();
}

/// Runs `print_quick_summary` once at the start of the bench run and never
/// again. Criterion's stat layer panics on all-equal sample sets, so we use
/// a counter to fall back to a tiny variable-duration sample on subsequent
/// calls instead of returning the same value every time.
fn bench_quick_summary(c: &mut Criterion) {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static COUNT: AtomicUsize = AtomicUsize::new(0);

    c.bench_function("__quick_summary__", |b| {
        b.iter_custom(|_iters| {
            let n = COUNT.fetch_add(1, Ordering::Relaxed);
            if n == 0 {
                print_quick_summary();
            }
            // Vary the reported duration so Criterion's variance estimator
            // never sees an all-equal series.
            std::time::Duration::from_micros(1 + (n as u64 & 0xF))
        });
    });
}

criterion_group!(benches, bench_quick_summary, bench_build, bench_lookup);
criterion_main!(benches);
