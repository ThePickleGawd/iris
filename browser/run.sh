#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

NODE_BIN="${NODE_BIN:-/Users/rohanshankar/.nvm/versions/node/v22.18.0/bin/node}"
NPM_CLI="${NPM_CLI:-/Users/rohanshankar/.nvm/versions/node/v22.18.0/lib/node_modules/npm/bin/npm-cli.js}"

if [ ! -x "$NODE_BIN" ]; then
  NODE_BIN="$(command -v node)"
fi
if [ ! -f "$NPM_CLI" ]; then
  NPM_CLI="$(dirname "$(dirname "$NODE_BIN")")/lib/node_modules/npm/bin/npm-cli.js"
fi

export PATH="$(dirname "$NODE_BIN"):$PATH"

PORT="${BROWSER_SERVICE_PORT:-8010}"
PIDS="$(lsof -ti:"$PORT" 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  kill $PIDS 2>/dev/null || true
fi

if [ ! -d node_modules ]; then
  "$NODE_BIN" "$NPM_CLI" install
fi

"$NODE_BIN" stagehand-service.mjs
