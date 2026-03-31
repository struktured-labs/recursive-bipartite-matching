# Agent Notes (2026-03-29)

## What happened while you were away

### i16 regret saturation fix
The 25M RBM run at -2.58 bb/hand was broken because i16 regrets (±32,767)
were saturating after ~10M+ iterations — `add_regret` clamps to ±32767, so
once a regret hits the ceiling it's stuck there forever, corrupting the strategy.

**Fix: periodic regret halving.** Every `regret_scale_every` iterations (default
1M), all regrets in the arena are divided by 2. This:
- Prevents saturation at any iteration count
- Acts as DCFR-style discounting (recent regrets weighted more)
- Costs almost nothing — one linear pass over contiguous `Vec<i16>`

### Files changed
- `config.rs` — new `regret_scale_every: u64` field on TrainConfig (default 1M)
- `compact_state.rs` — new `halve_regrets()` method + test
- `train.rs` — wired into both single-threaded and parallel loops
- `main.rs` — `--regret-scale-every N` CLI flag, shown in training banner

### Experiment running (PID 660830)
```
./target/release/rbm-mccfr \
  --iterations 25000000 \
  --threads 0 \
  --bucket-method rbm \
  --rbm-epsilon 1.5 \
  --dcfr --lcfr \
  --regret-scale-every 1000000 \
  --report-every 500000 \
  --checkpoint-every 5000000 \
  --play 1000 \
  --output strategy_rbm_25m_eps1.5_scaled.bin
```

Log: `logs/rbm_25m_eps1.5_scaled_20260329_120551.log`

This is the same config as the best 5M result (-2.05 bb/hand at eps=1.5),
scaled to 25M with the saturation fix. If it works, it should beat -2.05.

**Target: beat -1.11 bb/hand.**

### What to do next
1. Check the log for the final bb/hand result
2. Add the result to BENCHMARKS.md
3. If still not beating -1.11, investigate:
   - The 2x info set gap vs OCaml (game tree differences)
   - Whether `regret_scale_every=1M` is too aggressive/conservative
   - Try eps=1.0 or eps=2.0
4. Delete this file when done — it's just a handoff note
