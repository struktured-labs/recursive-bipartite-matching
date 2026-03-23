use criterion::{criterion_group, criterion_main, Criterion};

fn bench_placeholder(c: &mut Criterion) {
    c.bench_function("info_key_hash", |b| {
        let buckets = [34u32, 29, 78, 3];
        b.iter(|| {
            rbm_mccfr::info_key::make_info_key(&buckets, 2, b"cc/kk/kh")
        })
    });
}

criterion_group!(benches, bench_placeholder);
criterion_main!(benches);
