#!/bin/bash
cd "$(dirname "$0")"

# Load repository-root .env into process env, if present.
if [ -f "../.env" ]; then
  set -a
  source "../.env"
  set +a
fi

# Kill any existing Electron/Vite processes for this app
lsof -ti:5180 | xargs kill -9 2>/dev/null
pkill -f "electron \\." 2>/dev/null

npm run app:dev
