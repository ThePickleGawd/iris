#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ -f "../.env" ]; then
  set -a
  source "../.env"
  set +a
fi

PORT="${PORT:-8000}"
PIDS="$(lsof -ti:"$PORT" 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  kill $PIDS 2>/dev/null || true
fi

PORT="$PORT" uv run python app.py
