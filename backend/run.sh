#!/bin/bash
cd "$(dirname "$0")"
PORT="${PORT:-8000}" uv run python app.py
