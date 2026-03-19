#!/bin/bash
# launch_resume_169b.sh - Launch on-demand r6i.12xlarge to resume 169b training.
#
# Workflow:
#   1. Upload latest source to S3
#   2. Launch r6i.12xlarge ON-DEMAND (384GB RAM, no spot reclamation)
#   3. Instance downloads 50M checkpoint, evaluates vs Slumbot, resumes to 100M
#
# Cost: r6i.12xlarge = ~$3.02/hr on-demand. Estimated 20hr = ~$60.

set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

INSTANCE_TYPE="r6i.12xlarge"
AMI_ID="ami-0ec10929233384c7f"  # Ubuntu 24.04 Noble us-east-1
KEY_NAME="rbm-training"
SG_NAME="rbm-ssh"
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
S3_BUCKET="rbm-training-results-${ACCOUNT_ID}"
INSTANCE_PROFILE_NAME="rbm-training-profile"
RUN_ID="resume-169b-100M-$(date +%Y%m%d-%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "============================================"
echo "  RBM Resume Training Launcher"
echo "============================================"
echo "  Region:      $AWS_DEFAULT_REGION"
echo "  Instance:    $INSTANCE_TYPE (ON-DEMAND, 384GB RAM)"
echo "  Target:      169b, 50M → 100M total iterations"
echo "  Run ID:      $RUN_ID"
echo "  S3 Bucket:   $S3_BUCKET"
echo "  Est. cost:   ~\$60 (20hr × \$3.02/hr)"
echo "============================================"
echo ""

# ----------------------------------------------------------------
# Step 1: Upload source
# ----------------------------------------------------------------
echo ">>> Step 1: Upload source"

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
# Step 2: Get infrastructure IDs
# ----------------------------------------------------------------
echo ">>> Step 2: Infrastructure"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)

echo "    VPC: $VPC_ID  Subnet: $SUBNET_ID  SG: $SG_ID"

# ----------------------------------------------------------------
# Step 3: Build user-data (embed setup script directly)
# ----------------------------------------------------------------
echo ">>> Step 3: Building user-data"

python3 - "$SCRIPT_DIR/setup_resume_169b.sh" "$S3_BUCKET" "$RUN_ID" << 'PYEOF'
import base64, sys

setup_path, s3_bucket, run_id = sys.argv[1:4]

with open(setup_path) as f:
    setup_script = f.read()

setup_b64 = base64.b64encode(setup_script.encode()).decode()

user_data = f"""#!/bin/bash
set -x
exec > /var/log/rbm-bootstrap.log 2>&1

echo '{setup_b64}' | base64 -d > /home/ubuntu/setup_resume.sh
chmod +x /home/ubuntu/setup_resume.sh
chown ubuntu:ubuntu /home/ubuntu/setup_resume.sh

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

su - ubuntu -c "nohup /home/ubuntu/setup_resume.sh '{s3_bucket}' '$INSTANCE_ID' '{run_id}' > /home/ubuntu/training.log 2>&1 &"
echo 'Setup launched.'
"""

# EC2 user-data raw limit is 16KB (AWS CLI base64-encodes it → 25600 bytes)
raw_size = len(user_data.encode())
if raw_size > 16384:
    print(f"    ERROR: user-data too large ({raw_size} bytes > 16384 raw limit)")
    sys.exit(1)

# Save RAW script - AWS CLI will base64-encode it via file:// prefix
with open("/tmp/rbm-userdata.sh", "w") as f:
    f.write(user_data)
print(f"    User-data: {raw_size} bytes raw")
PYEOF

# ----------------------------------------------------------------
# Step 4: Launch ON-DEMAND instance
# ----------------------------------------------------------------
echo ">>> Step 4: Launching ON-DEMAND instance"

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
  --tag-specifications "ResourceType=instance,Tags=[
    {Key=Name,Value=rbm-resume-169b-100M},
    {Key=Project,Value=rbm-training},
    {Key=RunId,Value=$RUN_ID}
  ]" \
  --user-data "file:///tmp/rbm-userdata.sh" \
  --query 'Instances[0].InstanceId' \
  --output text)

rm -f /tmp/rbm-userdata-b64.txt
echo "    Instance launched: $INSTANCE_ID"

# ----------------------------------------------------------------
# Step 5: Wait for running + show info
# ----------------------------------------------------------------
echo ">>> Step 5: Waiting for instance..."

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo ""
echo "============================================"
echo "  Instance Running!"
echo "============================================"
echo ""
echo "  Instance ID:  $INSTANCE_ID"
echo "  Public IP:    $PUBLIC_IP"
echo "  Type:         $INSTANCE_TYPE (on-demand, 384GB RAM)"
echo "  Cost:         ~\$3.02/hr"
echo "  Run ID:       $RUN_ID"
echo ""
echo "  SSH:"
echo "    ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo ""
echo "  Monitor:"
echo "    ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP} tail -f /home/ubuntu/training.log"
echo ""
echo "  Check status:"
echo "    aws --region $AWS_DEFAULT_REGION ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text"
echo ""
echo "  Results:"
echo "    aws s3 ls s3://$S3_BUCKET/results/ --recursive | grep 169b"
echo ""
echo "  Timeline:"
echo "    ~10 min   Setup (OCaml, deps)"
echo "    ~5 min    Download 50M checkpoint (28.9GB)"
echo "    ~20 min   50M Slumbot eval (2000 hands)"
echo "    ~12-18hr  Train 50M → 100M total"
echo "    ~20 min   100M Slumbot eval (2000 hands)"
echo ""
echo "  Instance auto-terminates when done."
echo "  Manual terminate: aws --region $AWS_DEFAULT_REGION ec2 terminate-instances --instance-ids $INSTANCE_ID"
echo "============================================"
