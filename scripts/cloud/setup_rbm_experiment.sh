#!/bin/bash
# setup_rbm_experiment.sh - RBM bucketing scaling experiment.
#
# Train with RBM bucketing, checkpoint every 5M iterations,
# evaluate each checkpoint against Slumbot with 25K hands.
#
# Usage: setup_rbm_experiment.sh <s3_bucket> <instance_id> <run_id>

set -euo pipefail

S3_BUCKET="${1:-rbm-training-results-325614625768}"
INSTANCE_ID="${2:-unknown}"
RUN_ID="${3:-rbm-experiment}"

N_BUCKETS=169
TOTAL_ITERS=50000000
CHECKPOINT_EVERY=5000000
SLUMBOT_HANDS=25000
RBM_EPSILON=0.5

WORK_DIR="/home/ubuntu/rbm"
RESULTS_DIR="/home/ubuntu/results"
LOG_FILE="/home/ubuntu/training.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "  RBM Bucketing Scaling Experiment"
echo "============================================"
echo "  Instance:     $INSTANCE_ID"
echo "  Run ID:       $RUN_ID"
echo "  Buckets:      $N_BUCKETS"
echo "  Bucketing:    RBM (epsilon=$RBM_EPSILON)"
echo "  Training:     $TOTAL_ITERS iterations (parallel)"
echo "  Checkpoint:   every $CHECKPOINT_EVERY iterations"
echo "  Slumbot eval: $SLUMBOT_HANDS hands per checkpoint"
echo "  S3 Bucket:    $S3_BUCKET"
echo "  Started:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  CPUs:         $(nproc)"
echo "  Memory:       $(free -h | awk '/^Mem:/{print $2}')"
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
  libgmp-dev libffi-dev jq bc \
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
echo "    Built in $(($(date +%s) - t0))s"

# ----------------------------------------------------------------
# Phase 5: Iterative train + evaluate loop
# ----------------------------------------------------------------
echo ""
echo ">>> Phase 5: Train + evaluate loop"
echo "    Total: $TOTAL_ITERS iters, checkpoint every $CHECKPOINT_EVERY"
echo "    Eval: $SLUMBOT_HANDS hands per checkpoint"
echo ""

cd "$WORK_DIR"
eval $(opam env --switch=rbm)
export OCAMLRUNPARAM="s=4M,o=200"

ITERS_DONE=0
CHECKPOINT_NUM=0
RESUME_FLAG=""

# Results accumulator
echo "checkpoint,total_iters,mbb_per_hand,bb_per_hand,ci_lo,ci_hi,stddev,se,significant,info_sets_p0,info_sets_p1,train_time_s,eval_time_s" \
  > "$RESULTS_DIR/scaling_curve.csv"

while [ $ITERS_DONE -lt $TOTAL_ITERS ]; do
  ITERS_THIS_ROUND=$CHECKPOINT_EVERY
  REMAINING=$((TOTAL_ITERS - ITERS_DONE))
  if [ $ITERS_THIS_ROUND -gt $REMAINING ]; then
    ITERS_THIS_ROUND=$REMAINING
  fi

  CHECKPOINT_NUM=$((CHECKPOINT_NUM + 1))
  NEW_TOTAL=$((ITERS_DONE + ITERS_THIS_ROUND))
  echo "============================================"
  echo "  Checkpoint $CHECKPOINT_NUM: training $ITERS_THIS_ROUND iters → $NEW_TOTAL total"
  echo "============================================"

  # --- Train ---
  t_train=$(date +%s)
  CKPT_FILE="checkpoint_${NEW_TOTAL}.dat"

  set +e
  dune exec -- rbm-slumbot-client \
    --train $ITERS_THIS_ROUND \
    --buckets $N_BUCKETS \
    --hands 0 \
    --mock \
    --bucket-method rbm \
    --rbm-epsilon $RBM_EPSILON \
    --checkpoint-every $ITERS_THIS_ROUND \
    --checkpoint-prefix "checkpoint_${NEW_TOTAL}" \
    $RESUME_FLAG \
    --parallel \
    2>&1 | tee "$RESULTS_DIR/train_${NEW_TOTAL}.log"
  TRAIN_EXIT=${PIPESTATUS[0]}
  set -e

  TRAIN_TIME=$(( $(date +%s) - t_train ))
  echo "    Training: exit=$TRAIN_EXIT, time=${TRAIN_TIME}s"

  # Find the actual checkpoint file (parallel saves as prefix_final_N.dat)
  ACTUAL_CKPT=$(ls -t checkpoint_${NEW_TOTAL}*.dat 2>/dev/null | head -1)
  if [ -z "$ACTUAL_CKPT" ]; then
    echo "    ERROR: No checkpoint file found! Trying to continue..."
    ACTUAL_CKPT=""
  else
    echo "    Checkpoint: $ACTUAL_CKPT ($(du -h "$ACTUAL_CKPT" | cut -f1))"
    # Upload checkpoint to S3
    echo "    Uploading checkpoint to S3..."
    aws s3 cp "$ACTUAL_CKPT" "s3://$S3_BUCKET/checkpoints_rbm_experiment/$ACTUAL_CKPT" &
  fi

  # --- Evaluate against Slumbot ---
  echo "    Evaluating vs Slumbot ($SLUMBOT_HANDS hands)..."
  t_eval=$(date +%s)

  EVAL_RESUME=""
  if [ -n "$ACTUAL_CKPT" ]; then
    EVAL_RESUME="--resume $ACTUAL_CKPT"
  fi

  set +e
  dune exec -- rbm-slumbot-client \
    --train 1 \
    --buckets $N_BUCKETS \
    --hands $SLUMBOT_HANDS \
    --bucket-method rbm \
    --rbm-epsilon $RBM_EPSILON \
    $EVAL_RESUME \
    2>&1 | tee "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log"
  EVAL_EXIT=${PIPESTATUS[0]}
  set -e

  EVAL_TIME=$(( $(date +%s) - t_eval ))

  # Extract results
  MBB=$(grep -oP '[-0-9.]+(?= mbb/hand)' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | tail -1 2>/dev/null || echo "N/A")
  BB=$(grep -oP 'Average:\s+[-0-9.]+(?= bb/hand)' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | grep -oP '[-0-9.]+' | tail -1 2>/dev/null || echo "N/A")
  CI_LO=$(grep -oP '95% CI:\s+\[[-0-9.]+' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | grep -oP '[-0-9.]+$' 2>/dev/null || echo "N/A")
  CI_HI=$(grep -oP ', [-0-9.]+\]' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | grep -oP '[-0-9.]+' 2>/dev/null || echo "N/A")
  STDDEV=$(grep -oP 'Std dev:\s+[-0-9.]+' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | grep -oP '[-0-9.]+$' 2>/dev/null || echo "N/A")
  SE=$(grep -oP 'Std error:\s+[-0-9.]+' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | grep -oP '[-0-9.]+$' 2>/dev/null || echo "N/A")
  SIG=$(grep -oP 'Significant:\s+\w+' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | awk '{print $2}' 2>/dev/null || echo "N/A")
  P0_INFO=$(grep -oP 'P0=\d+' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | tail -1 | grep -oP '\d+' 2>/dev/null || echo "0")
  P1_INFO=$(grep -oP 'P1=\d+' "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" | tail -1 | grep -oP '\d+' 2>/dev/null || echo "0")

  echo "    >>> ${NEW_TOTAL} iters: ${MBB} mbb/hand, CI=[${CI_LO}, ${CI_HI}] bb/hand, sig=${SIG} <<<"

  # Append to CSV
  echo "${CHECKPOINT_NUM},${NEW_TOTAL},${MBB},${BB},${CI_LO},${CI_HI},${STDDEV},${SE},${SIG},${P0_INFO},${P1_INFO},${TRAIN_TIME},${EVAL_TIME}" \
    >> "$RESULTS_DIR/scaling_curve.csv"

  # Upload eval results
  aws s3 cp "$RESULTS_DIR/slumbot_${NEW_TOTAL}.log" \
    "s3://$S3_BUCKET/results/rbm_experiment/slumbot_${NEW_TOTAL}.txt" || true
  aws s3 cp "$RESULTS_DIR/scaling_curve.csv" \
    "s3://$S3_BUCKET/results/rbm_experiment/scaling_curve.csv" || true

  # Set up resume for next round
  if [ -n "$ACTUAL_CKPT" ]; then
    RESUME_FLAG="--resume $ACTUAL_CKPT"
  fi

  ITERS_DONE=$NEW_TOTAL
  echo ""
done

# ----------------------------------------------------------------
# Phase 6: Final summary
# ----------------------------------------------------------------
TOTAL_TIME=$(( $(date +%s) - OVERALL_START ))

echo ""
echo "============================================"
echo "  RBM Experiment Complete"
echo "============================================"
echo ""
echo "  Scaling curve:"
cat "$RESULTS_DIR/scaling_curve.csv"
echo ""
echo "  Total time: ${TOTAL_TIME}s"
echo "============================================"

# Upload final results
aws s3 cp "$RESULTS_DIR/scaling_curve.csv" \
  "s3://$S3_BUCKET/results/rbm_experiment/scaling_curve_final.csv" || true
cp "$LOG_FILE" "$RESULTS_DIR/full_log.txt"
aws s3 cp "$RESULTS_DIR/full_log.txt" \
  "s3://$S3_BUCKET/results/rbm_experiment/full_log.txt" || true

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
