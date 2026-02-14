#!/bin/bash
cd "$(dirname "$0")"

# Load repository-root .env into process env, if present.
if [ -f "../.env" ]; then
  set -a
  source "../.env"
  set +a
fi

# Kill any existing backend server on port 8000
lsof -ti:${PORT:-8000} | xargs kill -9 2>/dev/null

PORT="${PORT:-8000}" uv run python app.py
