#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

cleanup() {
  kill "${BACKEND_PID:-}" "${MAC_PID:-}" 2>/dev/null || true
  wait "${BACKEND_PID:-}" "${MAC_PID:-}" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

bash backend/run.sh &
BACKEND_PID=$!

bash mac/run.sh &
MAC_PID=$!

wait "$BACKEND_PID" "$MAC_PID"
