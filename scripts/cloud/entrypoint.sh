#!/usr/bin/env bash
# entrypoint.sh -- Container entrypoint for distributed MCCFR training.
#
# Runs MCCFR training for a configurable number of iterations, saves
# the strategy file, and optionally uploads it to S3.
#
# Environment variables (optional):
#   S3_BUCKET    -- S3 bucket for strategy upload (e.g., my-rbm-strategies)
#   S3_PREFIX    -- S3 key prefix (default: strategies/)
#   WORKER_ID    -- Unique worker identifier (default: hostname)
#   RUN_ID       -- Training run identifier (default: timestamp)
#
# Command-line arguments are passed through to the training command.

set -euo pipefail

WORKER_ID="${WORKER_ID:-$(hostname)}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
S3_PREFIX="${S3_PREFIX:-strategies/}"
OUTPUT_DIR="/home/opam/rbm/results"
OUTPUT_FILE="${OUTPUT_DIR}/strategy_${WORKER_ID}.dat"

mkdir -p "$OUTPUT_DIR"

echo "=== RBM Distributed MCCFR Worker ==="
echo "  Worker ID:  $WORKER_ID"
echo "  Run ID:     $RUN_ID"
echo "  Output:     $OUTPUT_FILE"
echo "  Arguments:  $*"
echo ""

# Parse arguments for the training command
ITERATIONS=100000
BUCKETS=20
CUSTOM_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --buckets)
      BUCKETS="$2"
      shift 2
      ;;
    --output)
      CUSTOM_OUTPUT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      shift
      ;;
  esac
done

if [[ -n "$CUSTOM_OUTPUT" ]]; then
  OUTPUT_FILE="$CUSTOM_OUTPUT"
fi

echo "Training MCCFR: iterations=$ITERATIONS buckets=$BUCKETS"
echo "Start time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_TIME=$(date +%s)

# Run training using the dedicated NL MCCFR trainer.
# This saves raw cfr_state (regret_sum + strategy_sum) in Marshal format,
# which is required for correct distributed merging.
cd /home/opam/rbm
opam exec -- dune exec -- rbm-train-mccfr-nl \
  --iterations "$ITERATIONS" \
  --buckets "$BUCKETS" \
  --output "$OUTPUT_FILE"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "Training complete in ${ELAPSED}s"
echo "Strategy file: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"

# Upload to S3 if bucket is configured
if [[ -n "${S3_BUCKET:-}" ]]; then
  S3_KEY="${S3_PREFIX}${RUN_ID}/strategy_${WORKER_ID}.dat"
  echo ""
  echo "Uploading to s3://${S3_BUCKET}/${S3_KEY}..."
  aws s3 cp "$OUTPUT_FILE" "s3://${S3_BUCKET}/${S3_KEY}"
  echo "Upload complete."

  # Also upload a metadata file
  METADATA_FILE="${OUTPUT_DIR}/metadata_${WORKER_ID}.json"
  cat > "$METADATA_FILE" <<METAEOF
{
  "worker_id": "$WORKER_ID",
  "run_id": "$RUN_ID",
  "iterations": $ITERATIONS,
  "buckets": $BUCKETS,
  "elapsed_seconds": $ELAPSED,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "strategy_file": "$S3_KEY"
}
METAEOF
  aws s3 cp "$METADATA_FILE" "s3://${S3_BUCKET}/${S3_PREFIX}${RUN_ID}/metadata_${WORKER_ID}.json"
  echo "Metadata uploaded."
fi

echo ""
echo "=== Worker $WORKER_ID finished ==="
