//! Diagnostic: distribution of i16 regret values in a trained arena.
//!
//! If the regret-halving + DCFR-discount fixes work, regrets should be
//! widely distributed across [-32767, 32767]. If we see piles at ±32767
//! (saturation) or piles at zero (over-halving), something's wrong.
//!
//! Reads a `regret_p0.bin` or `regret_p1.bin` mmap arena directly.

use std::fs::File;
use std::io::Read;

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| {
        "/home/struktured/projects/recursive-bipartite-matching/tmp/rbm_unified_eps0.5_20M/regret_p1.bin".to_string()
    });
    eprintln!("Reading: {}", path);

    let mut f = File::open(&path).expect("open");
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).expect("read");
    let n = buf.len() / 2;
    eprintln!("File size: {} bytes = {} i16 entries", buf.len(), n);

    let n_f32 = buf.len() / 4;
    let mut nz_count = 0u64;
    let mut max_abs = 0.0f32;
    let mut min_v = f32::INFINITY;
    let mut max_v = f32::NEG_INFINITY;
    let mut at_zero = 0u64;

    for i in 0..n_f32 {
        let v = f32::from_le_bytes([buf[i*4], buf[i*4+1], buf[i*4+2], buf[i*4+3]]);
        if v == 0.0 { at_zero += 1; continue; }
        nz_count += 1;
        if v.abs() > max_abs { max_abs = v.abs(); }
        if v < min_v { min_v = v; }
        if v > max_v { max_v = v; }
    }
    let n = n_f32;
    let max_abs = max_abs as i32;
    let min_v = min_v as i16;
    let max_v = max_v as i16;
    let sat_neg = 0u64;
    let sat_pos = 0u64;
    let bins = [0u64; 21];

    println!("Total entries:    {}", n);
    println!("Zero entries:     {} ({:.2}%)", at_zero, 100.0 * at_zero as f64 / n as f64);
    println!("Non-zero:         {} ({:.2}%)", nz_count, 100.0 * nz_count as f64 / n as f64);
    println!("Saturated (≤ -32700): {} ({:.4}% of nz)", sat_neg, 100.0 * sat_neg as f64 / nz_count.max(1) as f64);
    println!("Saturated (≥  32700): {} ({:.4}% of nz)", sat_pos, 100.0 * sat_pos as f64 / nz_count.max(1) as f64);
    println!("Min: {}, Max: {}, MaxAbs: {}", min_v, max_v, max_abs);
    println!();
    println!("Histogram (21 bins of width ~3120 each):");
    let max_count = bins.iter().copied().max().unwrap_or(1);
    for (i, &c) in bins.iter().enumerate() {
        let lo = i as i32 * 3120 - 32768;
        let hi = (i + 1) as i32 * 3120 - 32768;
        let bar_len = (60 * c / max_count.max(1)) as usize;
        println!("  [{:6}, {:6}) {:>10} {}", lo, hi, c, "#".repeat(bar_len));
    }
}
