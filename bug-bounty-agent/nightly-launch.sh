#!/usr/bin/env bash
# Queue tonight's orchestrator run and detach it from the terminal.
# Run this before you go to sleep.
#
# Usage:
#   bash nightly-launch.sh scope.yaml
#   bash nightly-launch.sh scope.yaml --phases recon scan
#
# Output and logs go to ./output/ and ./nightly.log
set -Eeuo pipefail

SCOPE="${1:-scope.yaml}"
shift || true
EXTRA_ARGS="${*}"
LOG="nightly.log"
PID_FILE="nightly.pid"

if [[ ! -f "$SCOPE" ]]; then
  echo "ERROR: scope file not found: $SCOPE"
  echo "Usage: bash nightly-launch.sh scope.yaml"
  exit 1
fi

# Kill any previous run
if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE")"
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Stopping previous run (PID $OLD_PID)..."
    kill "$OLD_PID" || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

echo "Starting overnight run: scope=$SCOPE extra=${EXTRA_ARGS:-none}"
echo "Log: $LOG"
echo "Kill with: kill \$(cat $PID_FILE)"

nohup python3 orchestrator.py --scope "$SCOPE" $EXTRA_ARGS \
  > "$LOG" 2>&1 &

echo $! > "$PID_FILE"
echo "PID: $(cat "$PID_FILE") — good night."
