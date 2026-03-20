#!/bin/bash
# setup_parallel_169b.sh - Resume from 60M with parallel MCCFR + streaming checkpoints.
#
# Key improvements over setup_resume_169b.sh:
#   - Chunked checkpoint format (no OOM during save)
#   - Parallel MCCFR training (uses all available cores)
#   - 25K Slumbot hands for statistical significance (±0.5 bb/hand CI)
#
# Plan:
#   1. Install OCaml 5.2 + deps (~10 min)
#   2. Download source + build (~2 min)
#   3. Download 60M checkpoint from S3 (~5 min, 31GB)
#   4. Convert checkpoint to chunked format (avoids future OOM)
#   5. Evaluate 60M strategy vs Slumbot: 25K hands (~45 min)
#   6. Resume training: 140M more → 200M total (parallel, ~4-6 hr)
#   7. Checkpoint every 25M iters (chunked format, safe)
#   8. Evaluate 200M strategy vs Slumbot: 25K hands (~45 min)
#   9. Upload results + self-terminate

set -euo pipefail

S3_BUCKET="${1:-rbm-training-results-325614625768}"
INSTANCE_ID="${2:-unknown}"
RUN_ID="${3:-parallel-169b-200M}"

N_BUCKETS=169
RESUME_ITERS=140000000  # 140M more → 200M total
CHECKPOINT_EVERY=25000000
SLUMBOT_HANDS=25000
CHECKPOINT_S3_KEY="checkpoints_169b_200M/checkpoint_10000000.dat"
CHECKPOINT_LOCAL="checkpoint_60M_total.dat"

WORK_DIR="/home/ubuntu/rbm"
RESULTS_DIR="/home/ubuntu/results"
LOG_FILE="/home/ubuntu/training.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "  RBM Parallel MCCFR Training (169b → 200M)"
echo "============================================"
echo "  Instance:    $INSTANCE_ID"
echo "  Run ID:      $RUN_ID"
echo "  Buckets:     $N_BUCKETS"
echo "  Resume from: 60M total (S3: $CHECKPOINT_S3_KEY)"
echo "  Train:       $RESUME_ITERS more iterations (PARALLEL)"
echo "  Target:      200M total iterations"
echo "  Checkpoint:  every ${CHECKPOINT_EVERY} iters (chunked format)"
echo "  Slumbot:     $SLUMBOT_HANDS hands (stat. significant)"
echo "  S3 Bucket:   $S3_BUCKET"
echo "  Started:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  CPUs:        $(nproc)"
echo "  Memory:      $(free -h | awk '/^Mem:/{print $2}')"
echo "============================================"
echo ""

mkdir -p "$RESULTS_DIR"
OVERALL_START=$(date +%s)

# ----------------------------------------------------------------
# Phase 1: System packages
# ----------------------------------------------------------------
echo ">>> Phase 1: System packages"
t0=$(date +%s)

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential gcc g++ make m4 \
  opam git curl unzip pkg-config \
  libgmp-dev libffi-dev \
  jq bc \
  2>&1 | tail -3

if ! command -v aws &>/dev/null; then
  curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  cd /tmp && unzip -q awscliv2.zip && sudo ./aws/install 2>&1 | tail -1
  cd /home/ubuntu
fi

echo "    Done in $(($(date +%s) - t0))s"

# ----------------------------------------------------------------
# Phase 2: OCaml 5.2
# ----------------------------------------------------------------
echo ">>> Phase 2: OCaml 5.2 via opam"
t0=$(date +%s)

opam init --auto-setup --disable-sandboxing --bare -y 2>&1 | tail -3
eval $(opam env)
opam switch create rbm 5.2.1 -y 2>&1 | tail -5
eval $(opam env --switch=rbm)

echo "    $(ocaml --version)"
echo "    Done in $(($(date +%s) - t0))s"

# ----------------------------------------------------------------
# Phase 3: OCaml deps
# ----------------------------------------------------------------
echo ">>> Phase 3: OCaml dependencies"
t0=$(date +%s)

opam install -y dune core core_unix ppx_jane domainslib yojson 2>&1 | tail -5
eval $(opam env --switch=rbm)

echo "    Done in $(($(date +%s) - t0))s"

# ----------------------------------------------------------------
# Phase 4: Download source + build
# ----------------------------------------------------------------
echo ">>> Phase 4: Download source + build"
t0=$(date +%s)

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

aws s3 cp "s3://$S3_BUCKET/source/rbm-source.tar.gz" /tmp/rbm-source.tar.gz
tar xzf /tmp/rbm-source.tar.gz -C "$WORK_DIR"
rm -f /tmp/rbm-source.tar.gz

export OCAMLRUNPARAM="s=4M,o=200"

eval $(opam env --switch=rbm)
dune build 2>&1

echo "    Built. Binaries:"
ls -la _build/default/bin/slumbot_client.exe 2>/dev/null && echo "      slumbot_client OK" || echo "      slumbot_client MISSING"

echo "    Done in $(($(date +%s) - t0))s"

# ----------------------------------------------------------------
# Phase 5: Download checkpoint from S3
# ----------------------------------------------------------------
echo ">>> Phase 5: Download 60M checkpoint from S3"
t0=$(date +%s)

aws s3 cp "s3://$S3_BUCKET/$CHECKPOINT_S3_KEY" "$WORK_DIR/$CHECKPOINT_LOCAL"
CKPT_SIZE=$(stat -c%s "$WORK_DIR/$CHECKPOINT_LOCAL")
echo "    Downloaded: $CHECKPOINT_LOCAL ($(echo "scale=1; $CKPT_SIZE / 1073741824" | bc) GB)"
echo "    Done in $(($(date +%s) - t0))s"

# ----------------------------------------------------------------
# Phase 6: SKIP — 60M eval already done twice (confirmed -1.3 to -1.5 bb/hand)
# ----------------------------------------------------------------
echo ">>> Phase 6: SKIPPED (60M eval done in prior runs: -1.28/-1.45 bb/hand)"
MBB_60M="skipped"
CI_60M="see prior runs"

# ----------------------------------------------------------------
# Phase 7: Resume training from 60M → 200M total (PARALLEL)
# ----------------------------------------------------------------
NUM_CORES=$(nproc)
echo ">>> Phase 7: Resume PARALLEL training ($RESUME_ITERS iters on $NUM_CORES cores)"
echo "    Starting at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    Memory before training: $(free -h | awk '/^Mem:/{print $4}') free"
t0=$(date +%s)

cd "$WORK_DIR"
eval $(opam env --switch=rbm)

# Upload checkpoints as they appear (background process)
(
  while true; do
    for ckpt in "$WORK_DIR"/checkpoint_*.dat; do
      if [ -f "$ckpt" ] && [ -s "$ckpt" ]; then
        ckpt_name=$(basename "$ckpt")
        marker="/tmp/uploaded_${ckpt_name}"
        if [ ! -f "$marker" ]; then
          echo "    [S3-bg] Uploading $ckpt_name..."
          aws s3 cp "$ckpt" "s3://$S3_BUCKET/checkpoints_169b_parallel/$ckpt_name" && \
            touch "$marker"
        fi
      fi
    done
    sleep 300
  done
) &
UPLOAD_PID=$!

set +e
dune exec -- rbm-slumbot-client \
  --resume "$CHECKPOINT_LOCAL" \
  --train $RESUME_ITERS \
  --buckets $N_BUCKETS \
  --hands $SLUMBOT_HANDS \
  --checkpoint-every $CHECKPOINT_EVERY \
  --checkpoint-prefix checkpoint \
  --parallel \
  --domains 8 \
  2>&1 | tee "$RESULTS_DIR/training_200M.log"
TRAIN_EXIT=${PIPESTATUS[0]}
set -e

kill $UPLOAD_PID 2>/dev/null || true

TRAIN_TIME=$(($(date +%s) - t0))
echo "    Training exit code: $TRAIN_EXIT"
echo "    Training time: ${TRAIN_TIME}s"

MBB_200M=$(grep -oP '[-0-9.]+(?= mbb/hand)' "$RESULTS_DIR/training_200M.log" | tail -1 2>/dev/null || echo "N/A")
CI_200M=$(grep -oP '95% CI:.*' "$RESULTS_DIR/training_200M.log" | tail -1 2>/dev/null || echo "N/A")
LAST_ITER=$(grep -oP '\[Compact-MCCFR-NL\] iter \K\d+' "$RESULTS_DIR/training_200M.log" | tail -1 || echo "0")
echo "    >>> 200M RESULT: ${MBB_200M} mbb/hand | ${CI_200M} <<<"
echo "    >>> Last iteration: ${LAST_ITER} <<<"

# ----------------------------------------------------------------
# Phase 8: Upload all results to S3
# ----------------------------------------------------------------
echo ">>> Phase 8: Upload results"

for ckpt in "$WORK_DIR"/checkpoint_*.dat; do
  if [ -f "$ckpt" ] && [ -s "$ckpt" ]; then
    ckpt_name=$(basename "$ckpt")
    echo "    Uploading $ckpt_name..."
    aws s3 cp "$ckpt" "s3://$S3_BUCKET/checkpoints_169b_parallel/$ckpt_name" || true
  fi
done

aws s3 cp "$RESULTS_DIR/training_200M.log" \
  "s3://$S3_BUCKET/results/results_169b_200M_parallel.txt" || true

TOTAL_TIME=$(( $(date +%s) - OVERALL_START ))
META_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
INST_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $META_TOKEN" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "unknown")

cat > "$RESULTS_DIR/summary.json" << EOF
{
  "run_id": "$RUN_ID",
  "instance_id": "$INSTANCE_ID",
  "instance_type": "$INST_TYPE",
  "n_buckets": $N_BUCKETS,
  "resumed_from": "60M total (10M into 100M run)",
  "additional_iterations": $RESUME_ITERS,
  "target_total": "200M",
  "parallel_cores": $NUM_CORES,
  "last_completed_iter": $LAST_ITER,
  "training_status": "$([ ${TRAIN_EXIT:-0} -eq 0 ] && echo 'completed' || echo 'killed')",
  "slumbot_60M_mbb": "$MBB_60M",
  "slumbot_60M_ci": "$CI_60M",
  "slumbot_200M_mbb": "$MBB_200M",
  "slumbot_200M_ci": "$CI_200M",
  "train_time_s": $TRAIN_TIME,
  "total_time_s": $TOTAL_TIME,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo ""
echo "  Summary:"
cat "$RESULTS_DIR/summary.json"

aws s3 cp "$RESULTS_DIR/summary.json" \
  "s3://$S3_BUCKET/results/summary_169b_200M_parallel.json" || true

cp "$LOG_FILE" "$RESULTS_DIR/training_full.log"
aws s3 cp "$RESULTS_DIR/training_full.log" \
  "s3://$S3_BUCKET/results/training_full_169b_200M_parallel.log" || true

echo ""
echo "============================================"
echo "  DONE: ${TOTAL_TIME}s total"
echo "  60M Slumbot:  ${MBB_60M} mbb/hand | ${CI_60M}"
echo "  200M Slumbot: ${MBB_200M} mbb/hand | ${CI_200M}"
echo "============================================"

# ----------------------------------------------------------------
# Phase 9: Self-terminate
# ----------------------------------------------------------------
echo ">>> Terminating instance $INSTANCE_ID"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>&1 || {
  echo "!!! SELF-TERMINATION FAILED !!!"
  echo "!!! RUN: aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION !!!"
}
