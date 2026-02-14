#!/bin/bash
cd "$(dirname "$0")"
PORT="${PORT:-5001}" uv run python app.py
