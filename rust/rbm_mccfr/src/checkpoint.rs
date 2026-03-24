/// Checkpoint save/load for MCCFR strategy data.
///
/// Binary format ("RBMRUST1"):
///   Magic:       "RBMRUST1" (8 bytes)
///   N_p0:        u64 (little-endian) — number of P0 info sets
///   For each P0 entry:
///     key:       u64 (LE)
///     n_actions: u32 (LE)
///     probs:     [f64; n_actions] (LE) — averaged strategy probabilities
///   N_p1:        u64 (LE)
///   For each P1 entry:
///     key:       u64 (LE)
///     n_actions: u32 (LE)
///     probs:     [f64; n_actions] (LE)
///
/// The averaged strategy (not raw regrets) is written, since that is all
/// OCaml needs for Slumbot play.

use std::io::{self, Read, Write, BufWriter, BufReader};
use std::fs::File;
use std::path::Path;
use crate::cfr_state::{self, CfrState};

const MAGIC: &[u8; 8] = b"RBMRUST1";

/// Save the averaged strategy for both players to a binary file.
pub fn save_averaged_strategy(
    path: &Path,
    states: &[CfrState; 2],
) -> io::Result<()> {
    let file = File::create(path)?;
    let mut w = BufWriter::new(file);

    // Magic
    w.write_all(MAGIC)?;

    // Write each player
    for player in 0..2 {
        let avg = cfr_state::average_strategy(&states[player]);
        let n_entries = avg.len() as u64;
        w.write_all(&n_entries.to_le_bytes())?;

        for (&key, probs) in &avg {
            w.write_all(&key.to_le_bytes())?;
            let n_actions = probs.len() as u32;
            w.write_all(&n_actions.to_le_bytes())?;
            for &p in probs {
                // Write as f64 for OCaml compatibility
                w.write_all(&(p as f64).to_le_bytes())?;
            }
        }
    }

    w.flush()?;
    Ok(())
}

/// Save raw CFR states (regrets + strategy sums) for resume capability.
pub fn save_raw_states(
    path: &Path,
    states: &[CfrState; 2],
    iteration: u64,
) -> io::Result<()> {
    let file = File::create(path)?;
    let mut w = BufWriter::new(file);

    // Magic for raw checkpoint
    w.write_all(b"RBMRAW01")?;
    w.write_all(&iteration.to_le_bytes())?;

    for player in 0..2 {
        let n_entries = states[player].len() as u64;
        w.write_all(&n_entries.to_le_bytes())?;

        for (&key, entry) in &states[player].entries {
            w.write_all(&key.to_le_bytes())?;
            w.write_all(&(entry.n_actions as u32).to_le_bytes())?;
            // Write all data (regrets + strategy sums) as f32
            for &val in &entry.data {
                w.write_all(&val.to_le_bytes())?;
            }
        }
    }

    w.flush()?;
    Ok(())
}

/// Load raw CFR states from a checkpoint file.
/// Returns (states, iteration) on success.
pub fn load_raw_states(path: &Path) -> io::Result<([CfrState; 2], u64)> {
    let file = File::open(path)?;
    let mut r = BufReader::new(file);

    let mut magic = [0u8; 8];
    r.read_exact(&mut magic)?;
    if &magic != b"RBMRAW01" {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad magic"));
    }

    let mut buf8 = [0u8; 8];
    r.read_exact(&mut buf8)?;
    let iteration = u64::from_le_bytes(buf8);

    let mut states = [CfrState::new(100_000), CfrState::new(100_000)];

    for player in 0..2 {
        r.read_exact(&mut buf8)?;
        let n_entries = u64::from_le_bytes(buf8) as usize;

        for _ in 0..n_entries {
            r.read_exact(&mut buf8)?;
            let key = u64::from_le_bytes(buf8);

            let mut buf4 = [0u8; 4];
            r.read_exact(&mut buf4)?;
            let n_actions = u32::from_le_bytes(buf4) as u8;

            let entry = states[player].find_or_add(key, n_actions);
            let data_len = n_actions as usize * 2;
            for i in 0..data_len {
                r.read_exact(&mut buf4)?;
                entry.data[i] = f32::from_le_bytes(buf4);
            }
        }
    }

    Ok((states, iteration))
}

/// Load averaged strategy from a checkpoint file.
/// Returns a pair of maps: key -> Vec<f64> for each player.
pub fn load_averaged_strategy(
    path: &Path,
) -> io::Result<[Vec<(u64, Vec<f64>)>; 2]> {
    let file = File::open(path)?;
    let mut r = BufReader::new(file);

    let mut magic = [0u8; 8];
    r.read_exact(&mut magic)?;
    if &magic != MAGIC {
        return Err(io::Error::new(io::ErrorKind::InvalidData,
            format!("bad magic: expected RBMRUST1, got {:?}", std::str::from_utf8(&magic))));
    }

    let mut result: [Vec<(u64, Vec<f64>)>; 2] = [Vec::new(), Vec::new()];

    for player in 0..2 {
        let mut buf8 = [0u8; 8];
        r.read_exact(&mut buf8)?;
        let n_entries = u64::from_le_bytes(buf8) as usize;

        result[player] = Vec::with_capacity(n_entries);

        for _ in 0..n_entries {
            r.read_exact(&mut buf8)?;
            let key = u64::from_le_bytes(buf8);

            let mut buf4 = [0u8; 4];
            r.read_exact(&mut buf4)?;
            let n_actions = u32::from_le_bytes(buf4) as usize;

            let mut probs = Vec::with_capacity(n_actions);
            for _ in 0..n_actions {
                r.read_exact(&mut buf8)?;
                probs.push(f64::from_le_bytes(buf8));
            }
            result[player].push((key, probs));
        }
    }

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn test_dir() -> PathBuf {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tmp");
        std::fs::create_dir_all(&dir).ok();
        dir
    }

    #[test]
    fn test_save_load_raw_roundtrip() {
        let path = test_dir().join("test_raw_roundtrip.bin");

        let mut states = [CfrState::new(100), CfrState::new(100)];
        // Add some entries
        {
            let e = states[0].find_or_add(42, 3);
            e.add_regret(0, 10.0);
            e.add_regret(1, -5.0);
            e.add_regret(2, 3.0);
            e.add_strategy(0, 100.0);
            e.add_strategy(1, 50.0);
            e.add_strategy(2, 80.0);
        }
        {
            let e = states[1].find_or_add(99, 2);
            e.add_regret(0, 7.5);
            e.add_regret(1, -2.0);
            e.add_strategy(0, 200.0);
            e.add_strategy(1, 300.0);
        }

        save_raw_states(&path, &states, 5000).unwrap();
        let (loaded, iter) = load_raw_states(&path).unwrap();

        assert_eq!(iter, 5000);
        assert_eq!(loaded[0].len(), 1);
        assert_eq!(loaded[1].len(), 1);

        let e0 = loaded[0].entries.get(&42).unwrap();
        assert_eq!(e0.n_actions, 3);
        assert!((e0.regret(0) - 10.0).abs() < 0.001);
        assert!((e0.regret(1) - (-5.0)).abs() < 0.001);
        assert!((e0.strategy(0) - 100.0).abs() < 0.001);

        let e1 = loaded[1].entries.get(&99).unwrap();
        assert_eq!(e1.n_actions, 2);
        assert!((e1.regret(0) - 7.5).abs() < 0.001);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_save_load_averaged_roundtrip() {
        let path = test_dir().join("test_avg_roundtrip.bin");

        let mut states = [CfrState::new(100), CfrState::new(100)];
        {
            let e = states[0].find_or_add(42, 3);
            e.add_strategy(0, 60.0);
            e.add_strategy(1, 30.0);
            e.add_strategy(2, 10.0);
        }
        {
            let e = states[1].find_or_add(99, 2);
            e.add_strategy(0, 70.0);
            e.add_strategy(1, 30.0);
        }

        save_averaged_strategy(&path, &states).unwrap();
        let loaded = load_averaged_strategy(&path).unwrap();

        assert_eq!(loaded[0].len(), 1);
        assert_eq!(loaded[1].len(), 1);

        let (key0, probs0) = &loaded[0][0];
        assert_eq!(*key0, 42);
        assert_eq!(probs0.len(), 3);
        assert!((probs0[0] - 0.6).abs() < 0.01);
        assert!((probs0[1] - 0.3).abs() < 0.01);
        assert!((probs0[2] - 0.1).abs() < 0.01);

        let (key1, probs1) = &loaded[1][0];
        assert_eq!(*key1, 99);
        assert_eq!(probs1.len(), 2);
        assert!((probs1[0] - 0.7).abs() < 0.01);
        assert!((probs1[1] - 0.3).abs() < 0.01);

        std::fs::remove_file(&path).ok();
    }
}
