# Active experiment chain — parallel-RBM ε=35 sweep

_Last updated: 2026-06-02_

**STATUS: Hostkey EPYC 9354 box (185.130.227.118) suspended / unreachable as of 2026-06-02.** SSH on port 22 times out; cutover to new EPYC 7402P / 512GB / $665-mo box is in flight. The in-progress `run_500M_t32_eps20_v6` was lost mid-phase-2.

Rescue watcher polls SSH from blackmage every 60 s — when the old host comes back (or the new one is provisioned and we can rsync from any snapshot), strategy.bin / cluster sidecars / chainer state get pulled to `/mnt/data/rbm-results/`. See `/mnt/data/rbm-results/RESCUE_PLAN.md`.

## Runs

| # | Run dir                                    | Iters | Status      | Result                          |
|---|--------------------------------------------|-------|-------------|---------------------------------|
| 1 | `run_100M_t32_eps35_parallel_rbm`         | 100M  | ✅ DONE      | **-1.41 [-1.76, -1.07] bb/h**  |
| 2 | `run_250M_t32_eps35_parallel_rbm`         | 250M  | ✅ DONE      | **-1.33 [-1.66, -0.99] bb/h**  |
| 3 | `run_1B_t32_eps35_parallel_rbm`           | 1B    | ✅ DONE      | **-1.25 [-1.58, -0.91] bb/h** (10/32 threads watchdog-killed) |
| 4 | `run_500M_t32_eps20_v6`                   | 500M  | 💀 LOST      | Phase 2 lost to suspension; phase-1 cluster set (482 clusters) gone unless rescue succeeds |
| 5 | `run_500M_t32_eps50_v6`                   | 500M  | 🚫 cancelled | Will re-queue on new Hostkey EPYC 7402P box |

## How to resume after a Claude session restart

```bash
# 1. Verify chainer is alive on Hostkey
ssh root@185.130.227.118 'ps aux | grep experiment_chainer | grep -v grep'

# 2. List completed runs
ssh root@185.130.227.118 'ls /root/run_*/.done 2>/dev/null'

# 3. For each completed run not yet in this repo, pull log + commit
ssh root@185.130.227.118 'cat /root/run_<name>/training.log' > results/<name>.log
# Extract result: grep -E '95% CI|Average:|Session complete'
# Write a one-pager in reports/, commit, push.
```

The auto-commit hook on the Hostkey side (`/root/auto_commit_results.sh`, if present) handles this automatically; this manual procedure is only needed if the hook is absent or failed.

## Reference

- PR #3: https://github.com/struktured-labs/recursive-bipartite-matching/pull/3
- Memory runbook: `runbook_session_restart.md`
- Hostkey binary: `/root/rbm_mccfr_v5/target/release/rbm-mccfr`
- Chainer: `/root/experiment_chainer.sh`, queue file: `/root/experiment_queue.txt`
