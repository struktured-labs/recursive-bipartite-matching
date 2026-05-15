# Operations: Hostkey experiment chain + blackmage cron

This doc describes the live operational setup for the parallel-RBM
scaling sweep. **If you are a Claude session bootstrapped from this repo,
read this first** — it tells you what's running where and what is and
isn't your job.

## High-level

- **Hostkey** (`root@185.130.227.118`, EPYC 9354, 32-core/64-thread, 755 GB
  RAM, $1.96/hr) runs the actual MCCFR training under a detached
  `experiment_chainer.sh` (PPID=1, survives Claude sessions ending).
  Queue file: `/root/experiment_queue.txt`. Binary: `/root/rbm_mccfr_v5/`.

- **blackmage** (the user's local workstation, where this repo is checked
  out) runs a cron job every 2 hours that:
  1. Verifies the chainer is alive on Hostkey; restarts it if dead and
     the queue still has work.
  2. Reports disk/memory pressure if alarming.
  3. Auto-harvests completed runs: for each `/root/run_*/` on Hostkey
     whose `.done` marker exists but whose `training.log` isn't yet in
     `results/`, it scp's the log, writes a one-pager in `reports/`,
     updates `EXPERIMENT_STATUS.md`, and commits + pushes to the current
     branch.

Net effect: **training runs and result-commits happen autonomously**.
A user (or new Claude session) only has to consult `EXPERIMENT_STATUS.md`
to see where the sweep stands.

## Cron entry

```cron
# parallel-RBM Hostkey health + result harvest (every 2 hours)
0 */2 * * * /home/struktured/projects/worktrees/rbm-parallel-cluster-merge/scripts/cron/hostkey_check_and_commit.sh
```

The script is checked into the repo at
`scripts/cron/hostkey_check_and_commit.sh`. Logs go to
`logs/cron/hostkey_check.log` (gitignored).

## How a Claude session should interact with this setup

**You should NOT:**

- Re-run training experiments locally for runs the cron will harvest.
- Manually scp + commit results — the cron does it. (Duplicate commits
  are harmless but pollute history.)
- Try to push to Hostkey from a cloud-scheduled remote agent — the cloud
  sandbox has no SSH credentials for `root@185.130.227.118`.

**You SHOULD:**

- Read `EXPERIMENT_STATUS.md` first to see what's running, done, or queued.
- Read recent commits and `reports/run_*.md` for prior results.
- Use `tail logs/cron/hostkey_check.log` to confirm the cron is firing on
  schedule.
- If the user asks "is X still running?" — ssh to Hostkey directly and
  check `pgrep -af experiment_chainer` and `ps aux | grep rbm-mccfr`.
- If you find the chainer dead but queue non-empty, just run the cron
  script manually: `./scripts/cron/hostkey_check_and_commit.sh` (it
  restarts the chainer itself).
- If you need to add a new experiment, append it to the
  `/root/experiment_queue.txt` line file on Hostkey AND add the run-dir
  name to the `RUNS=(…)` array in the cron script so it gets harvested.

## Files

| Path                                              | Purpose                                  |
|---------------------------------------------------|------------------------------------------|
| `scripts/cron/hostkey_check_and_commit.sh`        | The cron job script                      |
| `logs/cron/hostkey_check.log`                     | Cron job output (gitignored)             |
| `EXPERIMENT_STATUS.md`                            | Live status table of the sweep           |
| `results/<run_dir>.log`                           | Raw training.log per run                 |
| `reports/<run_dir>_<date>.md`                     | Auto-generated one-pager per run         |
| `reports/run_100M_parallel_rbm_2026_05_14.md`     | Hand-written analysis for the baseline   |
| Hostkey: `/root/experiment_chainer.sh`            | The chain orchestrator                   |
| Hostkey: `/root/experiment_queue.txt`             | One line per queued run                  |
| Hostkey: `/root/rbm_mccfr_v5/target/release/`     | The deployed binary                      |
| Hostkey: `/root/run_<name>/training.log`          | Per-run training log                     |
| Hostkey: `/root/run_<name>/.done`                 | Marker that a run finished cleanly       |

## Manual operations

```bash
# Dry-run the cron script (logs what it would do, no commits/restarts)
DRY_RUN=1 ./scripts/cron/hostkey_check_and_commit.sh

# Force a specific branch (useful while PR #3 is unmerged)
FORCE_BRANCH=fix/parallel-rbm-cluster-merge ./scripts/cron/hostkey_check_and_commit.sh

# Watch the cron log
tail -F logs/cron/hostkey_check.log

# Tail Hostkey training log in real time
ssh root@185.130.227.118 'tail -F /root/run_250M_t32_eps35_parallel_rbm/training.log'

# Verify cron is installed
crontab -l | grep hostkey_check
```

## Adding a new run to the chain

1. On Hostkey, append a line to the queue:
   ```bash
   ssh root@185.130.227.118 "echo 'run_<name>|--iterations <N> --threads 32 --rbm-epsilon <E> --mmap-arenas' >> /root/experiment_queue.txt"
   ```
2. Edit the `RUNS=(…)` array in `scripts/cron/hostkey_check_and_commit.sh`
   to include `run_<name>`.
3. If the chainer is idle (no queue entries when it started), restart it:
   ```bash
   ssh root@185.130.227.118 "pgrep -f experiment_chainer || nohup /root/experiment_chainer.sh > /root/experiment_chainer_stdout.log 2>&1 &"
   ```
4. Commit + push the updated cron script so future invocations harvest
   the new run.

## Cleanup

After the full sweep finishes:

- Hostkey: `nohup`'d chainer exits when the queue is empty. Old `run_*`
  directories can be pruned with `rm -rf /root/run_*_<scale>_*` (be
  careful — keep `.log`s for archival). Strategy `.bin` files are large
  (~150 GB each for 1B) and should be downloaded before deletion if
  needed.
- blackmage: remove the cron entry once no more runs are queued, or
  leave it — it's a no-op when queue is empty and `.done` files match
  the in-repo logs.
- Once PR #3 merges to `main`, update the cron's `REPO=` path to point
  at the main checkout if the worktree gets deleted.
