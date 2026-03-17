#!/usr/bin/env bash
# train_distributed.sh -- Launch N spot instances for distributed MCCFR training.
#
# Each instance trains MCCFR independently for the specified number of
# iterations, then uploads its strategy file to S3.  After all workers
# finish, download the strategies and merge them locally.
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Docker image pushed to ECR (see README.md)
#   - S3 bucket created
#
# Usage:
#   ./scripts/cloud/train_distributed.sh \
#     --instances 4 \
#     --iterations 500000 \
#     --buckets 20 \
#     --region us-east-1 \
#     --bucket my-rbm-strategies \
#     --image 123456789.dkr.ecr.us-east-1.amazonaws.com/rbm-trainer:latest
#
# The script will:
#   1. Launch N spot instances
#   2. Wait for all to complete
#   3. Download strategy files from S3
#   4. Merge them using rbm-merge-strategies
#   5. Terminate instances

set -euo pipefail

# ---- Defaults ----
NUM_INSTANCES=4
ITERATIONS=500000
BUCKETS=20
REGION="us-east-1"
S3_BUCKET=""
ECR_IMAGE=""
INSTANCE_TYPE="c6i.4xlarge"
SPOT_PRICE="0.40"
KEY_PAIR=""
SECURITY_GROUP=""
SUBNET=""
IAM_PROFILE="rbm-trainer-role"
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --instances)     NUM_INSTANCES="$2"; shift 2 ;;
    --iterations)    ITERATIONS="$2"; shift 2 ;;
    --buckets)       BUCKETS="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --bucket)        S3_BUCKET="$2"; shift 2 ;;
    --image)         ECR_IMAGE="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --spot-price)    SPOT_PRICE="$2"; shift 2 ;;
    --key-pair)      KEY_PAIR="$2"; shift 2 ;;
    --security-group) SECURITY_GROUP="$2"; shift 2 ;;
    --subnet)        SUBNET="$2"; shift 2 ;;
    --iam-profile)   IAM_PROFILE="$2"; shift 2 ;;
    --run-id)        RUN_ID="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---- Validate ----
if [[ -z "$S3_BUCKET" ]]; then
  echo "Error: --bucket is required (S3 bucket for strategy files)" >&2
  exit 1
fi
if [[ -z "$ECR_IMAGE" ]]; then
  echo "Error: --image is required (ECR Docker image URI)" >&2
  exit 1
fi

echo "=== Distributed MCCFR Training ==="
echo "  Run ID:       $RUN_ID"
echo "  Instances:    $NUM_INSTANCES x $INSTANCE_TYPE"
echo "  Iterations:   $ITERATIONS per worker"
echo "  Buckets:      $BUCKETS"
echo "  Total iters:  $((NUM_INSTANCES * ITERATIONS))"
echo "  Region:       $REGION"
echo "  S3 Bucket:    $S3_BUCKET"
echo "  Image:        $ECR_IMAGE"
echo "  Spot Price:   \$$SPOT_PRICE/hr"
echo ""

# ---- Generate user data script for each instance ----
generate_user_data() {
  local worker_id="$1"
  cat <<USERDATA
#!/bin/bash
set -euo pipefail

# Install Docker
apt-get update -y
apt-get install -y docker.io awscli
systemctl start docker

# Login to ECR
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $(echo "$ECR_IMAGE" | cut -d/ -f1)

# Pull and run the training container
docker pull $ECR_IMAGE

docker run --rm \
  -e S3_BUCKET=$S3_BUCKET \
  -e S3_PREFIX=strategies/ \
  -e WORKER_ID=worker_${worker_id} \
  -e RUN_ID=$RUN_ID \
  -e AWS_DEFAULT_REGION=$REGION \
  $ECR_IMAGE \
  --iterations $ITERATIONS \
  --buckets $BUCKETS

# Signal completion
aws s3 cp - "s3://$S3_BUCKET/strategies/$RUN_ID/done_worker_${worker_id}" <<< "done"

# Self-terminate
shutdown -h now
USERDATA
}

# ---- Launch spot instances ----
INSTANCE_IDS=()

for i in $(seq 0 $((NUM_INSTANCES - 1))); do
  echo "Launching worker $i..."

  USER_DATA=$(generate_user_data "$i" | base64 -w 0)

  LAUNCH_ARGS=(
    ec2 run-instances
    --region "$REGION"
    --image-id "resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
    --instance-type "$INSTANCE_TYPE"
    --instance-market-options '{"MarketType":"spot","SpotOptions":{"MaxPrice":"'"$SPOT_PRICE"'","SpotInstanceType":"one-time"}}'
    --user-data "$USER_DATA"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=rbm-worker-${i}},{Key=RunId,Value=${RUN_ID}},{Key=Project,Value=rbm-mccfr}]"
    --count 1
  )

  # Add optional parameters
  if [[ -n "$KEY_PAIR" ]]; then
    LAUNCH_ARGS+=(--key-name "$KEY_PAIR")
  fi
  if [[ -n "$SECURITY_GROUP" ]]; then
    LAUNCH_ARGS+=(--security-group-ids "$SECURITY_GROUP")
  fi
  if [[ -n "$SUBNET" ]]; then
    LAUNCH_ARGS+=(--subnet-id "$SUBNET")
  fi
  if [[ -n "$IAM_PROFILE" ]]; then
    LAUNCH_ARGS+=(--iam-instance-profile "Name=$IAM_PROFILE")
  fi

  INSTANCE_ID=$(aws "${LAUNCH_ARGS[@]}" --query 'Instances[0].InstanceId' --output text)
  INSTANCE_IDS+=("$INSTANCE_ID")
  echo "  Worker $i: $INSTANCE_ID"
done

echo ""
echo "All $NUM_INSTANCES instances launched."
echo "Instance IDs: ${INSTANCE_IDS[*]}"
echo ""

# ---- Wait for all workers to complete ----
echo "Waiting for all workers to complete..."
echo "  Checking s3://$S3_BUCKET/strategies/$RUN_ID/ for completion signals..."
echo ""

COMPLETED=0
MAX_WAIT=14400  # 4 hours
ELAPSED=0
CHECK_INTERVAL=60

while [[ $COMPLETED -lt $NUM_INSTANCES && $ELAPSED -lt $MAX_WAIT ]]; do
  sleep $CHECK_INTERVAL
  ELAPSED=$((ELAPSED + CHECK_INTERVAL))

  # Count completion signals in S3
  COMPLETED=$(aws s3 ls "s3://$S3_BUCKET/strategies/$RUN_ID/done_" --region "$REGION" 2>/dev/null | wc -l || echo 0)

  # Also count strategy files
  STRATEGIES=$(aws s3 ls "s3://$S3_BUCKET/strategies/$RUN_ID/strategy_" --region "$REGION" 2>/dev/null | wc -l || echo 0)

  MINUTES=$((ELAPSED / 60))
  echo "  [${MINUTES}m] $COMPLETED/$NUM_INSTANCES workers done, $STRATEGIES strategy files uploaded"
done

if [[ $COMPLETED -lt $NUM_INSTANCES ]]; then
  echo ""
  echo "WARNING: Only $COMPLETED/$NUM_INSTANCES workers completed within timeout."
  echo "Some instances may still be running. Check AWS console."
fi

echo ""
echo "=== Downloading strategy files ==="
RESULTS_DIR="results/${RUN_ID}"
mkdir -p "$RESULTS_DIR"

aws s3 sync "s3://$S3_BUCKET/strategies/$RUN_ID/" "$RESULTS_DIR/" --region "$REGION"

STRATEGY_FILES=("$RESULTS_DIR"/strategy_*.dat)
NUM_FILES=${#STRATEGY_FILES[@]}
echo "Downloaded $NUM_FILES strategy files."

# ---- Merge strategies ----
if [[ $NUM_FILES -gt 0 ]]; then
  echo ""
  echo "=== Merging $NUM_FILES strategy files ==="
  MERGED_FILE="$RESULTS_DIR/merged_strategy.dat"

  opam exec -- dune exec -- rbm-merge-strategies \
    -o "$MERGED_FILE" \
    "${STRATEGY_FILES[@]}"

  echo ""
  echo "Merged strategy: $MERGED_FILE"
  ls -lh "$MERGED_FILE"

  # Upload merged result
  aws s3 cp "$MERGED_FILE" "s3://$S3_BUCKET/strategies/$RUN_ID/merged_strategy.dat" --region "$REGION"
  echo "Uploaded merged strategy to S3."
fi

# ---- Terminate instances ----
echo ""
echo "=== Terminating instances ==="
for instance_id in "${INSTANCE_IDS[@]}"; do
  STATUS=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

  case "$STATUS" in
    terminated|shutting-down)
      echo "  $instance_id: already $STATUS"
      ;;
    *)
      echo "  $instance_id: terminating (was $STATUS)"
      aws ec2 terminate-instances --instance-ids "$instance_id" --region "$REGION" > /dev/null
      ;;
  esac
done

echo ""
echo "=== Training Run Complete ==="
echo "  Run ID:         $RUN_ID"
echo "  Workers:        $NUM_INSTANCES"
echo "  Iters/worker:   $ITERATIONS"
echo "  Total iters:    $((NUM_INSTANCES * ITERATIONS))"
echo "  Strategy files: $RESULTS_DIR/"
echo "  Merged:         $RESULTS_DIR/merged_strategy.dat"
echo ""
