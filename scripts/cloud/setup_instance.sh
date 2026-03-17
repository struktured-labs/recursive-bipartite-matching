#!/bin/bash
# setup_instance.sh - Runs on EC2 instance: install OCaml, build, train MCCFR, play Slumbot.
#
# Usage: setup_instance.sh <n_buckets> <iterations> <slumbot_hands> <s3_bucket> <instance_id> <run_id>
#
# Flow:
#   1. Install opam + OCaml 5.2 + project deps (~10-15 min)
#   2. Download source from S3 + dune build (~2 min)
#   3. Train MCCFR + play Slumbot in one pass (~varies by iterations)
#   4. Upload results to S3
#   5. Self-terminate

set -euo pipefail

N_BUCKETS="${1:-20}"
ITERATIONS="${2:-10000000}"
SLUMBOT_HANDS="${3:-1000}"
S3_BUCKET="${4:-rbm-training-results}"
INSTANCE_ID="${5:-unknown}"
RUN_ID="${6:-run-$(date +%Y%m%d-%H%M%S)}"

WORK_DIR="/home/ubuntu/rbm"
RESULTS_DIR="/home/ubuntu/results"
LOG_FILE="/home/ubuntu/training.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "  RBM MCCFR Cloud Training"
echo "============================================"
echo "  Instance:    $INSTANCE_ID"
echo "  Run ID:      $RUN_ID"
echo "  Buckets:     $N_BUCKETS"
echo "  Iterations:  $ITERATIONS"
echo "  Slumbot:     $SLUMBOT_HANDS hands"
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

# Install awscli v2 if not present
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

# Download source tarball from S3
aws s3 cp "s3://$S3_BUCKET/source/rbm-source.tar.gz" /tmp/rbm-source.tar.gz
tar xzf /tmp/rbm-source.tar.gz -C "$WORK_DIR"

eval $(opam env --switch=rbm)
dune build 2>&1

echo "    Built. Binaries:"
ls -la _build/default/bin/slumbot_client.exe 2>/dev/null && echo "      slumbot_client OK" || echo "      slumbot_client MISSING"
ls -la _build/default/bin/train_mccfr_nl.exe 2>/dev/null && echo "      train_mccfr_nl OK" || echo "      train_mccfr_nl MISSING"

echo "    Done in $(($(date +%s) - t0))s"

# ----------------------------------------------------------------
# Phase 5: Train MCCFR + Slumbot evaluation
# ----------------------------------------------------------------
echo ">>> Phase 5: Train ($ITERATIONS iter, $N_BUCKETS buckets) + Slumbot ($SLUMBOT_HANDS hands)"
t0=$(date +%s)

STRATEGY_FILE="$RESULTS_DIR/strategy_${N_BUCKETS}b_${ITERATIONS}i.sexp"
SLUMBOT_LOG="$RESULTS_DIR/slumbot_${N_BUCKETS}b_${ITERATIONS}i.log"

eval $(opam env --switch=rbm)
cd "$WORK_DIR"

# Train and play in one shot
# Use set +e to prevent script from dying on OOM kill
set +e
dune exec -- rbm-slumbot-client \
  --train "$ITERATIONS" \
  --buckets "$N_BUCKETS" \
  --hands "$SLUMBOT_HANDS" \
  --save "$STRATEGY_FILE" \
  2>&1 | tee "$SLUMBOT_LOG"
TRAIN_EXIT=${PIPESTATUS[0]}
set -e

TRAIN_EVAL_TIME=$(($(date +%s) - t0))

if [ $TRAIN_EXIT -ne 0 ]; then
  echo "    WARNING: Training process exited with code $TRAIN_EXIT (likely OOM)"
  LAST_ITER=$(grep -oP 'iter \K\d+' "$SLUMBOT_LOG" | tail -1 || echo "unknown")
  echo "    Last iteration reached: $LAST_ITER"
fi
echo "    Done in ${TRAIN_EVAL_TIME}s"

# ----------------------------------------------------------------
# Phase 6: Upload results to S3
# ----------------------------------------------------------------
echo ">>> Phase 6: Upload results"

cp "$LOG_FILE" "$RESULTS_DIR/training.log"

TOTAL_TIME=$(( $(date +%s) - OVERALL_START ))
SLUMBOT_MBB=$(grep -oP '[-0-9.]+(?= mbb/hand)' "$SLUMBOT_LOG" | tail -1 2>/dev/null || echo "N/A")
SLUMBOT_WINNINGS=$(grep -oP '(?<=Total winnings:  )[-0-9]+' "$SLUMBOT_LOG" 2>/dev/null || echo "0")
INFOSETS=$(grep -oP 'P0=\d+ P1=\d+ info' "$SLUMBOT_LOG" 2>/dev/null | tail -1 || echo "N/A")
LAST_COMPLETED_ITER=$(grep -oP 'iter \K\d+' "$SLUMBOT_LOG" | tail -1 2>/dev/null || echo "0")
TRAINING_STATUS=$([ "${TRAIN_EXIT:-0}" -eq 0 ] && echo "completed" || echo "oom_killed")

# Get instance type from metadata
META_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
INST_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $META_TOKEN" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "unknown")

cat > "$RESULTS_DIR/summary.json" << EOF
{
  "run_id": "$RUN_ID",
  "instance_id": "$INSTANCE_ID",
  "instance_type": "$INST_TYPE",
  "n_buckets": $N_BUCKETS,
  "iterations": $ITERATIONS,
  "slumbot_hands": $SLUMBOT_HANDS,
  "train_eval_time_s": $TRAIN_EVAL_TIME,
  "total_time_s": $TOTAL_TIME,
  "training_status": "$TRAINING_STATUS",
  "last_completed_iter": $LAST_COMPLETED_ITER,
  "slumbot_mbb": "$SLUMBOT_MBB",
  "slumbot_winnings": "$SLUMBOT_WINNINGS",
  "info_sets": "$INFOSETS",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "  Summary:"
cat "$RESULTS_DIR/summary.json"

S3_PREFIX="s3://$S3_BUCKET/results/$RUN_ID/${N_BUCKETS}b_${ITERATIONS}i"
aws s3 cp "$RESULTS_DIR/" "$S3_PREFIX/" --recursive 2>&1 || {
  echo "WARNING: S3 upload failed (non-fatal)"
}

echo ""
echo "============================================"
echo "  DONE: ${TOTAL_TIME}s total"
echo "  Slumbot: ${SLUMBOT_MBB} mbb/hand"
echo "  S3: $S3_PREFIX/"
echo "============================================"

# ----------------------------------------------------------------
# Phase 7: Self-terminate
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
