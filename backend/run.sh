#!/bin/bash
cd "$(dirname "$0")"
PORT="${PORT:-5050}" uv run python app.py
