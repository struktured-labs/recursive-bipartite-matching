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
        }
    }
}
