#!/bin/bash
# setup_decomposed.sh - Subgame-decomposed MCCFR training + Slumbot eval.
#
# Uses subgame decomposition for 10-50x speedup:
#   Phase 1: Blueprint preflop training (100K iters, fast)
#   Phase 2: Cluster flops via RBM distance
#   Phase 3: Train each subgame independently in parallel
#   Phase 4: Play 25K hands vs Slumbot

set -euo pipefail

S3_BUCKET="${1:-rbm-training-results-325614625768}"
INSTANCE_ID="${2:-unknown}"
RUN_ID="${3:-decomposed-experiment}"

N_BUCKETS=169
BLUEPRINT_ITERS=100000
SUBGAME_ITERS=50000
SUBGAME_EPSILON=0.5
RBM_EPSILON=0.5
N_FLOPS=200
SLUMBOT_HANDS=25000

WORK_DIR="/home/ubuntu/rbm"
RESULTS_DIR="/home/ubuntu/results"
LOG_FILE="/home/ubuntu/training.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "  Subgame-Decomposed MCCFR Experiment"
echo "============================================"
echo "  Instance:        $INSTANCE_ID"
echo "  Run ID:          $RUN_ID"
echo "  Buckets:         $N_BUCKETS"
echo "  Blueprint iters: $BLUEPRINT_ITERS"
echo "  Subgame iters:   $SUBGAME_ITERS"
echo "  Subgame epsilon: $SUBGAME_EPSILON"
echo "  RBM epsilon:     $RBM_EPSILON"
echo "  Flop samples:    $N_FLOPS"
echo "  Slumbot hands:   $SLUMBOT_HANDS"
echo "  S3 Bucket:       $S3_BUCKET"
echo "  Started:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  CPUs:            $(nproc)"
echo "  Memory:          $(free -h | awk '/^Mem:/{print $2}')"
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
# Phase 5: Decomposed training + Slumbot eval
# ----------------------------------------------------------------
echo ""
echo ">>> Phase 5: Decomposed training + Slumbot eval"
t0=$(date +%s)

cd "$WORK_DIR"
eval $(opam env --switch=rbm)
export OCAMLRUNPARAM="s=4M,o=200"

# Sweep subgame iterations: 50K, 100K, 200K
for SG_ITERS in 50000 100000 200000; do
  echo ""
  echo "============================================"
  echo "  Subgame iters: $SG_ITERS"
  echo "============================================"

  set +e
  dune exec -- rbm-slumbot-client \
    --decomposed \
    --blueprint-iters $BLUEPRINT_ITERS \
    --subgame-iters $SG_ITERS \
    --subgame-epsilon $SUBGAME_EPSILON \
    --n-flops $N_FLOPS \
    --buckets $N_BUCKETS \
    --bucket-method rbm \
    --rbm-epsilon $RBM_EPSILON \
    --hands $SLUMBOT_HANDS \
    2>&1 | tee "$RESULTS_DIR/decomposed_sg${SG_ITERS}.log"
  EXIT_CODE=${PIPESTATUS[0]}
  set -e

  echo "    Exit code: $EXIT_CODE"

  # Extract results
  MBB=$(grep -oP '[-0-9.]+(?= mbb/hand)' "$RESULTS_DIR/decomposed_sg${SG_ITERS}.log" | tail -1 2>/dev/null || echo "N/A")
  CI=$(grep -oP '95% CI:.*' "$RESULTS_DIR/decomposed_sg${SG_ITERS}.log" | tail -1 2>/dev/null || echo "N/A")
  echo "    >>> sg_iters=$SG_ITERS: $MBB mbb/hand, $CI <<<"

  # Upload results
  aws s3 cp "$RESULTS_DIR/decomposed_sg${SG_ITERS}.log" \
    "s3://$S3_BUCKET/results/decomposed/sg${SG_ITERS}.txt" || true
done

TOTAL_TIME=$(( $(date +%s) - OVERALL_START ))

echo ""
echo "============================================"
echo "  Decomposed Experiment Complete"
echo "  Total time: ${TOTAL_TIME}s"
echo "============================================"

# Upload full log
cp "$LOG_FILE" "$RESULTS_DIR/full_log.txt"
aws s3 cp "$RESULTS_DIR/full_log.txt" \
  "s3://$S3_BUCKET/results/decomposed/full_log.txt" || true

# ----------------------------------------------------------------
# Self-terminate
# ----------------------------------------------------------------
echo ">>> Terminating instance $INSTANCE_ID"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>&1 || {
  echo "!!! SELF-TERMINATION FAILED !!!"
}
