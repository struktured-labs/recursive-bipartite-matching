/// Game configuration matching OCaml's Nolimit_holdem.config.
#[repr(C)]
#[derive(Clone, Debug)]
pub struct GameConfig {
    pub small_blind: i32,
    pub big_blind: i32,
    pub starting_stack: i32,
    pub bet_fractions: Vec<f64>,
    pub max_raises_per_round: u8,
}

impl GameConfig {
    /// Slumbot config: 50/100 blinds, 20000 stack, [0.5, 1.0, 2.0] bet sizes.
    pub fn slumbot() -> Self {
        Self {
            small_blind: 50,
            big_blind: 100,
            starting_stack: 20_000,
            bet_fractions: vec![0.5, 1.0, 2.0],
            max_raises_per_round: 4,
        }
    }
}

/// Bucketing method for MCCFR training.
#[derive(Clone, Debug)]
pub enum BucketMethod {
    /// Equity-based bucketing: quantize hand score to a fixed number of buckets.
    Equity,
    /// RBM-based bucketing: online clustering via showdown distribution trees.
    /// Epsilon controls cluster granularity (smaller = more clusters).
    Rbm { epsilon: f64 },
}

impl Default for BucketMethod {
    fn default() -> Self {
        BucketMethod::Rbm { epsilon: 0.5 }
    }
}

/// Training configuration.
#[derive(Clone, Debug)]
pub struct TrainConfig {
    pub iterations: u64,
    pub report_every: u64,
    pub initial_size: usize,
    pub checkpoint_every: u64,
    pub prune_threshold: f64,
    pub dcfr: bool,
    pub lcfr: bool,
    pub n_buckets: u32,
    pub bucket_method: BucketMethod,
    /// Halve all regrets every N iterations. Acts as DCFR-like discounting
    /// that biases toward more recent learning. 0 = disabled.
    pub regret_scale_every: u64,
    /// Freeze CompactCfrState → FrozenCfrState after this many iterations.
    /// Replaces FxHashMap (~48B/key) with MPHF (~2.1 bits/key) + flat arrays.
    /// 0 = disabled (never freeze). Default: 5000000 (5M).
    pub freeze_after: u64,
    /// Use mmap-backed arenas instead of in-memory Vecs.
    /// Allows training to exceed physical RAM by paging cold entries to disk.
    /// Speed cost: ~2-3x for cold entries, negligible for hot entries.
    pub mmap_arenas: bool,
    /// In parallel-training mode, set to Some(thread_id) so the per-thread
    /// checkpoint file is named `checkpoint_t{tid}_{iter}.bin` instead of
    /// the single-thread `checkpoint_{iter}.bin`. None = single-thread mode
    /// (default), uses unsuffixed name.
    pub checkpoint_thread_id: Option<usize>,
}

impl Default for TrainConfig {
    fn default() -> Self {
        Self {
            iterations: 1_000_000,
            report_every: 10_000,
            initial_size: 1_000_000,
            checkpoint_every: 0,
            prune_threshold: -300_000_000.0,
            dcfr: false,
            lcfr: false,
            n_buckets: 169,
            bucket_method: BucketMethod::default(),
            regret_scale_every: 1_000_000,
            freeze_after: 5_000_000,
            mmap_arenas: false,
            checkpoint_thread_id: None,
        }
    }
}
