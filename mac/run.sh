#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ -f "../.env" ]; then
  set -a
  source "../.env"
  set +a
fi

PIDS="$(lsof -ti:5180 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  kill $PIDS 2>/dev/null || true
fi
pkill -f "electron \\." 2>/dev/null || true

npm run app:dev
