# Cloud Training for Distributed MCCFR

Run MCCFR (Monte Carlo Counterfactual Regret Minimization) training across
multiple AWS spot instances.  Each worker trains independently, then the
results are merged into a single strategy.

## How It Works

Distributed CFR exploits the additive nature of regret and strategy sums:
K workers each training for N iterations produce the same result (in
expectation) as a single worker training for K*N iterations.

1. Each spot instance runs a Docker container that trains MCCFR for N iterations
2. Each worker uploads its `cfr_state` (regret_sum + strategy_sum) to S3
3. After all workers finish, `rbm-merge-strategies` averages the tables
4. The merged strategy is evaluated against Slumbot or via self-play

## Prerequisites

### Install AWS CLI

```bash
# Ubuntu/Debian
sudo apt-get install awscli

# Or via pip
pip install awscli

# Verify
aws --version
```

### Configure Credentials

```bash
aws configure
# Enter:
#   AWS Access Key ID
#   AWS Secret Access Key
#   Default region (e.g., us-east-1)
#   Default output format: json
```

### Create S3 Bucket

```bash
BUCKET_NAME="rbm-mccfr-strategies"
aws s3 mb "s3://${BUCKET_NAME}" --region us-east-1
```

### Create IAM Role for Workers

Workers need S3 write access and ECR pull access.  Use the policy template
in `spot_config.json`:

```bash
# Create the role
aws iam create-role \
  --role-name rbm-trainer-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach the policy (edit spot_config.json first to fill in your bucket name)
aws iam put-role-policy \
  --role-name rbm-trainer-role \
  --policy-name rbm-s3-ecr-access \
  --policy-document file://scripts/cloud/spot_config.json

# Create instance profile
aws iam create-instance-profile --instance-profile-name rbm-trainer-role
aws iam add-role-to-instance-profile \
  --instance-profile-name rbm-trainer-role \
  --role-name rbm-trainer-role
```

### Build and Push Docker Image to ECR

```bash
# Set variables
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/rbm-trainer"

# Create ECR repository
aws ecr create-repository --repository-name rbm-trainer --region "$REGION"

# Login to ECR
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Build and push
docker build -t rbm-trainer -f scripts/cloud/Dockerfile .
docker tag rbm-trainer:latest "${ECR_REPO}:latest"
docker push "${ECR_REPO}:latest"
```

## Running Distributed Training

### Quick Start (4 workers, 500K iterations each = 2M total)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"

./scripts/cloud/train_distributed.sh \
  --instances 4 \
  --iterations 500000 \
  --buckets 20 \
  --region "$REGION" \
  --bucket rbm-mccfr-strategies \
  --image "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/rbm-trainer:latest" \
  --key-pair my-key-pair \
  --security-group sg-xxxxxxxx \
  --instance-type c6i.4xlarge
```

### Local Docker Test (verify image works)

```bash
# Build
docker build -t rbm-trainer -f scripts/cloud/Dockerfile .

# Run a small training locally
docker run --rm -v "$(pwd)/results:/home/opam/rbm/results" \
  rbm-trainer --iterations 10000 --buckets 10

# Check the output
ls -la results/
```

### Merge Strategies Manually

If you have strategy files from a previous run:

```bash
opam exec -- dune exec -- rbm-merge-strategies \
  -o merged_strategy.dat \
  results/strategy_worker_0.dat \
  results/strategy_worker_1.dat \
  results/strategy_worker_2.dat \
  results/strategy_worker_3.dat
```

### Evaluate Against Slumbot

```bash
# Mock mode (offline, against check/call bot)
./scripts/cloud/evaluate.sh \
  --strategy results/merged_strategy.dat \
  --hands 1000 \
  --mock

# Live mode (against real Slumbot)
./scripts/cloud/evaluate.sh \
  --strategy results/merged_strategy.dat \
  --hands 500 \
  --username YOUR_SLUMBOT_USERNAME \
  --password YOUR_SLUMBOT_PASSWORD
```

## Cost Estimates

Spot instance pricing varies by region and demand.  These are approximate
estimates for `us-east-1` as of 2026.

| Configuration | Instance | Spot $/hr | Workers | Hours | Total Cost |
|---------------|----------|-----------|---------|-------|------------|
| Small test    | c6i.2xlarge | ~$0.12 | 2 | 0.5 | ~$0.12 |
| Medium run    | c6i.4xlarge | ~$0.30 | 4 | 1.0 | ~$1.20 |
| Large run     | c6i.4xlarge | ~$0.30 | 8 | 2.0 | ~$4.80 |
| Production    | c6i.4xlarge | ~$0.30 | 16 | 4.0 | ~$19.20 |
| Budget (ARM)  | c7g.4xlarge | ~$0.22 | 8 | 2.0 | ~$3.52 |

**Training time estimates** (c6i.4xlarge, 16 vCPUs):

| Iterations | Buckets | Approx Time | Info Sets |
|------------|---------|-------------|-----------|
| 100K       | 10      | ~5 min      | ~50K      |
| 500K       | 20      | ~30 min     | ~500K     |
| 1M         | 20      | ~1 hr       | ~1M       |
| 5M         | 20      | ~5 hr       | ~3M       |

S3 storage: strategy files are typically 10-200 MB each, costing
fractions of a cent per month.

**Scaling rule of thumb**: 4 workers x 500K iterations ~ $1.20 and
produces a strategy equivalent to 2M single-threaded iterations.
Doubling workers halves wall-clock time at the same total cost.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Container build for OCaml training environment |
| `entrypoint.sh` | Container entrypoint (train + upload to S3) |
| `train_distributed.sh` | Launch N spot instances, wait, merge |
| `evaluate.sh` | Play merged strategy against Slumbot |
| `merge_strategies.ml` | Algorithm documentation (binary in `bin/`) |
| `spot_config.json` | EC2/IAM/security group configuration template |

## Architecture

```
                 +-----------+
                 |   S3      |
                 |  Bucket   |
                 +-----+-----+
                       ^
          upload       |       download
     +---------+-------+-------+---------+
     |         |               |         |
+----+----+  +-+-------+  +---+-----+  +-+-------+
| Worker 0|  | Worker 1|  | Worker 2|  | Worker 3|
| 500K it |  | 500K it |  | 500K it |  | 500K it |
+---------+  +---------+  +---------+  +---------+
  EC2 Spot     EC2 Spot     EC2 Spot     EC2 Spot

                       |
                       v merge
                 +-----------+
                 |  Local    |
                 |  Merge    |
                 +-----+-----+
                       |
                       v evaluate
                 +-----------+
                 |  Slumbot  |
                 |  Client   |
                 +-----------+
```

## Troubleshooting

**Spot instances get terminated**: Spot instances can be reclaimed by AWS.
The training script handles this gracefully -- partial results are still
uploaded.  Re-run with more workers to compensate.

**Docker build fails on ARM**: Use the x86 base image (default).  For ARM
(Graviton), change the Dockerfile FROM line to the ARM variant.

**Strategy files are incompatible**: All workers must use the same number
of buckets and the same bet fractions.  The merge tool does not validate
this; mismatched configs will produce incorrect results.

**Out of memory**: For large bucket counts (>30) or very long training
runs (>5M iterations), info-set tables can grow large.  Use r6i.2xlarge
(64 GB) instead of c6i.4xlarge (32 GB).
