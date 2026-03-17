#!/usr/bin/env bash
# evaluate.sh -- Play a merged strategy against Slumbot and report results.
#
# Downloads the merged strategy from S3 (or uses a local file), then
# plays N hands against Slumbot's API to measure performance in mbb/hand.
#
# Usage:
#   # From S3:
#   ./scripts/cloud/evaluate.sh \
#     --bucket my-rbm-strategies \
#     --run-id run_20260316_120000 \
#     --hands 500
#
#   # From local file:
#   ./scripts/cloud/evaluate.sh \
#     --strategy results/merged_strategy.dat \
#     --hands 500
#
#   # Mock mode (offline testing):
#   ./scripts/cloud/evaluate.sh \
#     --strategy results/merged_strategy.dat \
#     --hands 1000 \
#     --mock

set -euo pipefail

# ---- Defaults ----
S3_BUCKET=""
RUN_ID=""
STRATEGY_FILE=""
NUM_HANDS=200
BUCKETS=20
MOCK=false
VERBOSE=false
USERNAME=""
PASSWORD=""
REGION="us-east-1"

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)      S3_BUCKET="$2"; shift 2 ;;
    --run-id)      RUN_ID="$2"; shift 2 ;;
    --strategy)    STRATEGY_FILE="$2"; shift 2 ;;
    --hands)       NUM_HANDS="$2"; shift 2 ;;
    --buckets)     BUCKETS="$2"; shift 2 ;;
    --mock)        MOCK=true; shift ;;
    --verbose)     VERBOSE=true; shift ;;
    --username)    USERNAME="$2"; shift 2 ;;
    --password)    PASSWORD="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---- Get strategy file ----
if [[ -z "$STRATEGY_FILE" ]]; then
  if [[ -z "$S3_BUCKET" || -z "$RUN_ID" ]]; then
    echo "Error: specify either --strategy FILE or --bucket + --run-id" >&2
    exit 1
  fi

  STRATEGY_FILE="results/${RUN_ID}/merged_strategy.dat"
  mkdir -p "$(dirname "$STRATEGY_FILE")"

  echo "Downloading merged strategy from S3..."
  aws s3 cp \
    "s3://${S3_BUCKET}/strategies/${RUN_ID}/merged_strategy.dat" \
    "$STRATEGY_FILE" \
    --region "$REGION"
  echo "Downloaded: $STRATEGY_FILE ($(du -h "$STRATEGY_FILE" | cut -f1))"
  echo ""
fi

if [[ ! -f "$STRATEGY_FILE" ]]; then
  echo "Error: strategy file not found: $STRATEGY_FILE" >&2
  exit 1
fi

echo "=== Evaluating Strategy Against Slumbot ==="
echo "  Strategy: $STRATEGY_FILE"
echo "  Hands:    $NUM_HANDS"
echo "  Buckets:  $BUCKETS"
echo "  Mode:     $(if $MOCK; then echo 'MOCK (local)'; else echo 'LIVE (slumbot.com)'; fi)"
echo ""

# Build the command
CMD_ARGS=(
  opam exec -- dune exec -- rbm-slumbot-client
  --strategy "$STRATEGY_FILE"
  --hands "$NUM_HANDS"
  --buckets "$BUCKETS"
)

if $MOCK; then
  CMD_ARGS+=(--mock)
fi

if $VERBOSE; then
  CMD_ARGS+=(--verbose)
fi

if [[ -n "$USERNAME" ]]; then
  CMD_ARGS+=(--username "$USERNAME")
fi

if [[ -n "$PASSWORD" ]]; then
  CMD_ARGS+=(--password "$PASSWORD")
fi

# Run evaluation
"${CMD_ARGS[@]}"

echo ""
echo "=== Evaluation Complete ==="
