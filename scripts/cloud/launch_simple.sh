#!/bin/bash
# launch_simple.sh - Launch a single EC2 spot instance for MCCFR training.
#
# Usage:
#   ./scripts/cloud/launch_simple.sh [buckets] [iterations] [slumbot_hands]
#
# Defaults: 20 buckets, 10M iterations, 1000 Slumbot hands
#
# What this does:
#   1. Creates S3 bucket (if needed) and uploads source tarball
#   2. Creates IAM role + instance profile (if needed)
#   3. Creates SSH key pair + security group (if needed)
#   4. Builds user-data from setup_instance.sh (base64-encoded)
#   5. Launches EC2 spot instance
#   6. Waits for instance to start, shows SSH command + monitoring info
#
# The instance will self-terminate when training completes.
#
# Measured performance (c6i.xlarge, 4 vCPU):
#   Phase 1 (apt packages):    ~35s
#   Phase 2 (OCaml 5.2):       ~165s
#   Phase 3 (opam deps):       ~155s
#   Phase 4 (S3 download+build): ~10s
#   Phase 5 (training):        ~1000 iter/s (varies with info set size)
#   Abstraction build:         ~275s for 20 buckets
#
# Instance type selection:
#   Default: c6i.xlarge (4 vCPU, ~$0.06/hr spot) - fits 5 vCPU spot quota
#   Override: set INSTANCE_TYPE=c6i.8xlarge for 32 vCPU (~$0.55/hr) if quota allows
#   The training is single-threaded, so more vCPUs don't directly speed it up.
#   Larger instances help with opam compile time only.

set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

N_BUCKETS="${1:-20}"
ITERATIONS="${2:-10000000}"
SLUMBOT_HANDS="${3:-1000}"

# Configuration -- override INSTANCE_TYPE env var for larger instances
INSTANCE_TYPE="${INSTANCE_TYPE:-c6i.xlarge}"
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-0.20}"
AMI_ID="ami-0ec10929233384c7f"  # Ubuntu 24.04 Noble us-east-1
KEY_NAME="rbm-training"
SG_NAME="rbm-ssh"
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
S3_BUCKET="rbm-training-results-${ACCOUNT_ID}"
IAM_ROLE_NAME="rbm-training-role"
INSTANCE_PROFILE_NAME="rbm-training-profile"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "============================================"
echo "  RBM Cloud Training Launcher"
echo "============================================"
echo "  Region:      $AWS_DEFAULT_REGION"
echo "  Instance:    $INSTANCE_TYPE (spot, max \$$MAX_SPOT_PRICE/hr)"
echo "  Buckets:     $N_BUCKETS"
echo "  Iterations:  $ITERATIONS"
echo "  Slumbot:     $SLUMBOT_HANDS hands"
echo "  Run ID:      $RUN_ID"
echo "  S3 Bucket:   $S3_BUCKET"
echo "============================================"
echo ""

# ----------------------------------------------------------------
# Step 1: S3 bucket + upload source
# ----------------------------------------------------------------
echo ">>> Step 1: S3 bucket + source upload"

if ! aws s3 ls "s3://$S3_BUCKET" 2>/dev/null; then
  echo "    Creating bucket: $S3_BUCKET"
  aws s3 mb "s3://$S3_BUCKET" --region "$AWS_DEFAULT_REGION"
  aws s3api put-bucket-tagging --bucket "$S3_BUCKET" \
    --tagging 'TagSet=[{Key=Project,Value=rbm-training}]'
else
  echo "    Bucket exists: $S3_BUCKET"
fi

# Create lightweight source tarball (exclude binaries, build artifacts, large strategies)
echo "    Creating source tarball..."
cd "$PROJECT_DIR"
tar czf /tmp/rbm-source.tar.gz \
  --exclude='_build' \
  --exclude='.git' \
  --exclude='results/strategies/*.sexp' \
  --exclude='results/strategies/*.dat' \
  --exclude='strategy_*.dat' \
  --exclude='strategy_*.sexp' \
  --exclude='*.dat' \
  --exclude='tmp/' \
  --exclude='a.out' \
  .

echo "    Uploading source ($(du -h /tmp/rbm-source.tar.gz | cut -f1))..."
aws s3 cp /tmp/rbm-source.tar.gz "s3://$S3_BUCKET/source/rbm-source.tar.gz"
rm -f /tmp/rbm-source.tar.gz
echo "    Source uploaded."

# ----------------------------------------------------------------
# Step 2: IAM role + instance profile
# ----------------------------------------------------------------
echo ">>> Step 2: IAM role + instance profile"

if aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
  echo "    Role exists: $IAM_ROLE_NAME"
else
  echo "    Creating IAM role: $IAM_ROLE_NAME"
  aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' \
    --tags Key=Project,Value=rbm-training \
    --output text --query 'Role.Arn'

  aws iam put-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-name rbm-training-policy \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:PutObject\", \"s3:GetObject\", \"s3:ListBucket\"],
          \"Resource\": [
            \"arn:aws:s3:::$S3_BUCKET\",
            \"arn:aws:s3:::$S3_BUCKET/*\"
          ]
        },
        {
          \"Effect\": \"Allow\",
          \"Action\": \"ec2:TerminateInstances\",
          \"Resource\": \"*\",
          \"Condition\": {
            \"StringEquals\": {
              \"ec2:ResourceTag/Project\": \"rbm-training\"
            }
          }
        }
      ]
    }"
  echo "    Role created."
fi

if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
  echo "    Instance profile exists: $INSTANCE_PROFILE_NAME"
else
  echo "    Creating instance profile: $INSTANCE_PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$IAM_ROLE_NAME"
  echo "    Waiting 15s for IAM propagation..."
  sleep 15
fi

# ----------------------------------------------------------------
# Step 3: SSH key pair
# ----------------------------------------------------------------
echo ">>> Step 3: SSH key pair"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
  echo "    Key pair exists: $KEY_NAME"
else
  echo "    Creating key pair: $KEY_NAME"
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > "$HOME/.ssh/${KEY_NAME}.pem"
  chmod 400 "$HOME/.ssh/${KEY_NAME}.pem"
  echo "    Saved to ~/.ssh/${KEY_NAME}.pem"
fi

# ----------------------------------------------------------------
# Step 4: Security group
# ----------------------------------------------------------------
echo ">>> Step 4: Security group"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
  echo "    Security group exists: $SG_ID"
else
  echo "    Creating security group: $SG_NAME"
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "SSH access for RBM training instances" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0

  aws ec2 create-tags --resources "$SG_ID" \
    --tags Key=Project,Value=rbm-training Key=Name,Value=rbm-ssh

  echo "    Created: $SG_ID"
fi

# ----------------------------------------------------------------
# Step 5: Build user-data (Python for clean base64 encoding)
# ----------------------------------------------------------------
echo ">>> Step 5: Building user-data"

python3 - "$SCRIPT_DIR/setup_instance.sh" "$N_BUCKETS" "$ITERATIONS" \
  "$SLUMBOT_HANDS" "$S3_BUCKET" "$RUN_ID" << 'PYEOF'
import base64, sys

setup_path, n_buckets, iterations, slumbot_hands, s3_bucket, run_id = sys.argv[1:7]

with open(setup_path) as f:
    setup_script = f.read()

setup_b64 = base64.b64encode(setup_script.encode()).decode()

user_data = f"""#!/bin/bash
set -x
exec > /var/log/rbm-bootstrap.log 2>&1

echo '{setup_b64}' | base64 -d > /home/ubuntu/setup_instance.sh
chmod +x /home/ubuntu/setup_instance.sh
chown ubuntu:ubuntu /home/ubuntu/setup_instance.sh

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

su - ubuntu -c "nohup /home/ubuntu/setup_instance.sh '{n_buckets}' '{iterations}' '{slumbot_hands}' '{s3_bucket}' '$INSTANCE_ID' '{run_id}' > /home/ubuntu/training.log 2>&1 &"
echo 'Setup launched.'
"""

encoded = base64.b64encode(user_data.encode()).decode()
with open("/tmp/rbm-userdata-b64.txt", "w") as f:
    f.write(encoded)
print(f"    User-data: {len(user_data)} bytes")
PYEOF

# ----------------------------------------------------------------
# Step 6: Launch spot instance
# ----------------------------------------------------------------
echo ">>> Step 6: Launching spot instance"

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)

echo "    VPC: $VPC_ID  Subnet: $SUBNET_ID  SG: $SG_ID"

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" \
  --instance-market-options "{
    \"MarketType\": \"spot\",
    \"SpotOptions\": {
      \"MaxPrice\": \"$MAX_SPOT_PRICE\",
      \"SpotInstanceType\": \"one-time\",
      \"InstanceInterruptionBehavior\": \"terminate\"
    }
  }" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
  --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=rbm-training-${N_BUCKETS}b-${ITERATIONS}i},
    {Key=Project,Value=rbm-training},
    {Key=RunId,Value=$RUN_ID},
    {Key=Buckets,Value=$N_BUCKETS},
    {Key=Iterations,Value=$ITERATIONS}
  ]" \
  --user-data "file:///tmp/rbm-userdata-b64.txt" \
  --query 'Instances[0].InstanceId' \
  --output text)

rm -f /tmp/rbm-userdata-b64.txt
echo "    Instance launched: $INSTANCE_ID"

# ----------------------------------------------------------------
# Step 7: Wait for running + show info
# ----------------------------------------------------------------
echo ">>> Step 7: Waiting for instance..."

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

SPOT_PRICE=$(aws ec2 describe-spot-price-history \
  --instance-types "$INSTANCE_TYPE" \
  --product-descriptions "Linux/UNIX" \
  --start-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --query 'SpotPriceHistory[0].SpotPrice' \
  --output text 2>/dev/null || echo "unknown")

# Training speed: ~1000 iter/s for early iterations, slows to ~500 for >1M info sets
EST_TRAIN_MIN=$(echo "scale=0; $ITERATIONS / 1000 / 60" | bc)
EST_SETUP_MIN=7  # phases 1-4
EST_ABSTRACTION_MIN=$(echo "scale=0; $N_BUCKETS * 14 / 60" | bc)  # ~14s per bucket
EST_TOTAL_MIN=$((EST_SETUP_MIN + EST_ABSTRACTION_MIN + EST_TRAIN_MIN + 10))  # +10 for slumbot
EST_COST=$(echo "scale=2; $EST_TOTAL_MIN / 60 * $SPOT_PRICE" | bc 2>/dev/null || echo "N/A")

echo ""
echo "============================================"
echo "  Instance Running!"
echo "============================================"
echo ""
echo "  Instance ID:  $INSTANCE_ID"
echo "  Public IP:    $PUBLIC_IP"
echo "  Spot Price:   \$$SPOT_PRICE/hr"
echo "  Run ID:       $RUN_ID"
echo ""
echo "  SSH:"
echo "    ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo ""
echo "  Monitor:"
echo "    ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP} tail -f /home/ubuntu/training.log"
echo ""
echo "  Check status:"
echo "    aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $AWS_DEFAULT_REGION --query 'Reservations[0].Instances[0].State.Name' --output text"
echo ""
echo "  Results (when done):"
echo "    aws s3 cp s3://$S3_BUCKET/results/$RUN_ID/ results/cloud/$RUN_ID/ --recursive"
echo ""
echo "  Estimates:"
echo "    Setup:      ~${EST_SETUP_MIN} min"
echo "    Abstraction: ~${EST_ABSTRACTION_MIN} min ($N_BUCKETS buckets)"
echo "    Training:   ~${EST_TRAIN_MIN} min ($ITERATIONS iter @ ~1K/s)"
echo "    Total:      ~${EST_TOTAL_MIN} min"
echo "    Cost:       ~\$${EST_COST}"
echo ""
echo "  Instance auto-terminates when done."
echo "  Manual terminate: aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $AWS_DEFAULT_REGION"
echo "============================================"
