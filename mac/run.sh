#!/bin/bash
cd "$(dirname "$0")"

# Kill any existing Electron/Vite processes for this app
lsof -ti:5180 | xargs kill -9 2>/dev/null
pkill -f "electron \\." 2>/dev/null

npm run app:dev
