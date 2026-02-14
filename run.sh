#!/bin/bash
cd "$(dirname "$0")"

echo "Starting Iris..."

cleanup() {
    echo "Shutting down Iris..."
    # Kill entire process groups (children included)
    kill -- -$BACKEND_PID 2>/dev/null
    kill -- -$MAC_PID 2>/dev/null
    wait 2>/dev/null
    exit
}

# Run children in their own process groups
set -m

trap cleanup EXIT INT TERM

# Start backend in background
bash backend/run.sh &
BACKEND_PID=$!

# Give backend a moment to boot
sleep 2

# Start mac app in background
bash mac/run.sh &
MAC_PID=$!

# Bash 3.2 (default on macOS) does not support `wait -n`.
# Poll child processes and exit when either one dies; trap will cleanup both.
while true; do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$MAC_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done
