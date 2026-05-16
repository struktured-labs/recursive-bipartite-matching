# Active experiment chain — parallel-RBM ε=35 sweep

_Last updated: 2026-05-14_

The Hostkey chainer (`nohup`'d, PPID=1) is running the parallel-RBM scaling sweep on PR #3. **Experiments continue regardless of Claude session lifecycle.**

## Runs

| # | Run dir                                    | Iters | Status      | Result                          |
|---|--------------------------------------------|-------|-------------|---------------------------------|
| 1 | `run_100M_t32_eps35_parallel_rbm`         | 100M  | ✅ DONE      | **-1.41 [-1.76, -1.07] bb/h**  |
| 2 | `run_250M_t32_eps35_parallel_rbm`         | 250M  | ✅ DONE   | -1325.94 m [-1.66, -0.99] |
| 3 | `run_1B_t32_eps35_parallel_rbm`           | 1B    | ⏳ queued    | ETA ~95 hours after #2          |

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
