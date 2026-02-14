#!/bin/bash
cd "$(dirname "$0")"

# Kill any existing backend server on port 8000
lsof -ti:${PORT:-8000} | xargs kill -9 2>/dev/null

PORT="${PORT:-8000}" uv run python app.py
