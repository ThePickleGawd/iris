#!/bin/bash
cd "$(dirname "$0")"

echo "Starting Iris..."

# Start backend in background
bash backend/run.sh &
BACKEND_PID=$!

# Give backend a moment to boot
sleep 2

# Start mac app in foreground
bash mac/run.sh

# If mac app exits, clean up backend
kill $BACKEND_PID 2>/dev/null
