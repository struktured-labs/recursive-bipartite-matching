#!/bin/bash
#
# hostkey_check_and_commit.sh — blackmage cron job.
#
# Runs every 2 hours from struktured's crontab. Two responsibilities:
#
#   1. Hostkey health: verify the experiment_chainer.sh is still alive on
#      Hostkey (root@185.130.227.118). If it died but the queue isn't
#      empty, restart it. Log anomalies (disk near full, memory pressure,
#      OOM-killed processes).
#
#   2. Auto-harvest completed runs: for any /root/run_*/.done on Hostkey
#      whose training.log isn't yet in this repo, scp the log into
#      results/, write a one-pager report in reports/, update
#      EXPERIMENT_STATUS.md, and commit + push to the current branch.
#
# Env knobs:
#   DRY_RUN=1      — skip writes/commits/push, just print what would happen
#   FORCE_BRANCH=  — push to this branch regardless of repo HEAD
#
# Logs to logs/cron/hostkey_check.log (gitignored). Exits non-zero only on
# bugs in the script itself; transient ssh failures are logged and ignored
# so a flaky network at 03:00 doesn't blow up the cron mail.

set -uo pipefail

REPO="/home/struktured/projects/worktrees/rbm-parallel-cluster-merge"
HOSTKEY="root@185.130.227.118"
LOG_DIR="$REPO/logs/cron"
LOG="$LOG_DIR/hostkey_check.log"
DRY_RUN="${DRY_RUN:-0}"

# Runs in the chain. Add new entries here when the queue grows.
RUNS=(
  run_100M_t32_eps35_parallel_rbm
  run_250M_t32_eps35_parallel_rbm
  run_1B_t32_eps35_parallel_rbm
)

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date -Iseconds)] $*" | tee -a "$LOG" >&2
}

ssh_q() {
  # Quiet ssh with a connect timeout so a hung Hostkey doesn't wedge cron.
  ssh -o ConnectTimeout=15 -o BatchMode=yes -o ServerAliveInterval=10 \
      -o ServerAliveCountMax=3 "$HOSTKEY" "$@"
}

# --- pull repo so we commit on top of the latest tip ------------------------
cd "$REPO"
current_branch=$(git rev-parse --abbrev-ref HEAD)
target_branch="${FORCE_BRANCH:-$current_branch}"
log "starting check (branch=$target_branch, dry_run=$DRY_RUN)"

if ! git fetch origin --quiet 2>>"$LOG"; then
  log "WARN: git fetch failed; continuing with local state"
fi
if git rev-parse --verify "origin/$target_branch" >/dev/null 2>&1; then
  git pull --ff-only origin "$target_branch" --quiet 2>>"$LOG" || \
    log "WARN: git pull --ff-only failed (uncommitted local changes? rebased?)"
fi

# --- chainer health ---------------------------------------------------------
chainer_pid=$(ssh_q "pgrep -f experiment_chainer | head -1" 2>>"$LOG" || true)
queue_size=$(ssh_q "wc -l < /root/experiment_queue.txt" 2>>"$LOG" || echo 0)
queue_size=${queue_size//[^0-9]/}; queue_size=${queue_size:-0}

if [ -z "$chainer_pid" ]; then
  if [ "$queue_size" -gt 0 ]; then
    log "WARN: chainer not running but queue has $queue_size entries → restarting"
    if [ "$DRY_RUN" = "0" ]; then
      ssh_q "nohup /root/experiment_chainer.sh > /root/experiment_chainer_stdout.log 2>&1 &" \
        2>>"$LOG" && log "chainer restarted"
    else
      log "DRY_RUN: would restart chainer"
    fi
  else
    log "chainer not running, queue empty (sweep complete)"
  fi
else
  log "chainer alive (pid=$chainer_pid, queue=$queue_size)"
fi

# --- disk/memory pressure check --------------------------------------------
disk_pct=$(ssh_q "df --output=pcent /root | tail -1 | tr -d ' %'" 2>>"$LOG" || echo 0)
disk_pct=${disk_pct//[^0-9]/}; disk_pct=${disk_pct:-0}
mem_free_gb=$(ssh_q "free -g | awk '/^Mem:/ {print \$7}'" 2>>"$LOG" || echo 0)
mem_free_gb=${mem_free_gb//[^0-9]/}; mem_free_gb=${mem_free_gb:-0}
log "disk=${disk_pct}% used, mem_free=${mem_free_gb}GB"
[ "$disk_pct" -ge 90 ] && log "ALERT: disk ${disk_pct}% used"
[ "$mem_free_gb" -lt 5 ] 2>/dev/null && log "ALERT: only ${mem_free_gb}GB memory free"

# --- harvest completed runs -------------------------------------------------
new_runs=()
for run in "${RUNS[@]}"; do
  if [ -f "$REPO/results/${run}.log" ]; then continue; fi
  if ! ssh_q "test -f /root/${run}/.done" 2>>"$LOG"; then continue; fi

  log "harvesting $run"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would scp + commit $run"
    continue
  fi

  if ! scp -q -o ConnectTimeout=30 "$HOSTKEY:/root/${run}/training.log" \
       "$REPO/results/${run}.log" 2>>"$LOG"; then
    log "ERROR: scp failed for $run; will retry next tick"
    rm -f "$REPO/results/${run}.log"
    continue
  fi

  # Extract eval result.
  avg=$(grep -E '^\s+Average:.*bb/hand$' "$REPO/results/${run}.log" | head -1 | sed 's/^\s*//')
  ci=$(grep -E '^\s+95% CI:' "$REPO/results/${run}.log" | head -1 | sed 's/^\s*//')
  sig=$(grep -E '^\s+Significant:' "$REPO/results/${run}.log" | head -1 | sed 's/^\s*//')
  speed=$(grep -E '^Speed:' "$REPO/results/${run}.log" | head -1)
  wall=$(grep -E '^Training complete in' "$REPO/results/${run}.log" | head -1)
  cluster_line=$(grep -E 'Phase 1 done' "$REPO/results/${run}.log" | head -1)
  iters_tag=$(echo "$run" | grep -oE 'run_[0-9]+[MB]' | sed 's/run_//')

  date_str=$(date +%Y_%m_%d)
  report="$REPO/reports/${run}_${date_str}.md"
  cat > "$report" <<EOF
# ${run} — Slumbot eval result

**Auto-harvested:** $(date -Iseconds) by \`scripts/cron/hostkey_check_and_commit.sh\` on blackmage
**Branch:** ${target_branch}
**Full log:** \`results/${run}.log\`

## Headline

\`\`\`
$avg
$ci
$sig
\`\`\`

## Training stats

\`\`\`
$cluster_line
$wall
$speed
\`\`\`

See [run_100M_parallel_rbm_2026_05_14.md](run_100M_parallel_rbm_2026_05_14.md) for the equivalent format with full analysis for the 100M baseline run.
EOF

  # Update EXPERIMENT_STATUS.md (best-effort sed swap on the row for this run).
  if [ -f "$REPO/EXPERIMENT_STATUS.md" ]; then
    short_result=$(echo "${avg} ${ci}" | sed 's/Average:\s*//; s/95% CI:\s*//; s/bb\/hand//g; s/[[:space:]]\+/ /g')
    awk -v run="$run" -v result="$short_result" '
      $0 ~ run && /running|queued/ {
        sub(/🔄 running/, "✅ DONE")
        sub(/⏳ queued/, "✅ DONE")
        sub(/ETA[^|]*/, result)
      }
      { print }
    ' "$REPO/EXPERIMENT_STATUS.md" > "$REPO/EXPERIMENT_STATUS.md.tmp" \
      && mv "$REPO/EXPERIMENT_STATUS.md.tmp" "$REPO/EXPERIMENT_STATUS.md"
  fi

  new_runs+=("$run|$avg|$ci")
done

# --- single commit per harvest tick ----------------------------------------
if [ "${#new_runs[@]}" -gt 0 ]; then
  cd "$REPO"
  git add -A results/ reports/ EXPERIMENT_STATUS.md
  body=""
  for entry in "${new_runs[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"; avg="${rest%%|*}"; ci="${rest#*|}"
    body="${body}- ${name}: ${avg} | ${ci}"$'\n'
  done
  msg_subject="parallel-RBM eval: $(printf '%s, ' "${new_runs[@]%%|*}" | sed 's/, $//') (auto-harvested)"
  if [ "$DRY_RUN" = "0" ]; then
    git commit -m "$msg_subject" -m "$body" -m "Auto-committed by scripts/cron/hostkey_check_and_commit.sh on blackmage." 2>>"$LOG"
    git push origin "$target_branch" 2>>"$LOG" && log "pushed ${#new_runs[@]} harvested run(s) to origin/$target_branch"
  else
    log "DRY_RUN: would commit + push ${#new_runs[@]} runs"
  fi
else
  log "no new completed runs to harvest"
fi

log "tick complete"
