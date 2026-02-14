#!/bin/bash
cd "$(dirname "$0")"
IRIS_BACKEND_URL="${IRIS_BACKEND_URL:-http://localhost:5050}" uv run uvicorn server:app --host 0.0.0.0 --port "${PORT:-8000}"
