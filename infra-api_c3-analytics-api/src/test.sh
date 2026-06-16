#!/usr/bin/env bash
# Local smoke test for c3-analytics-api.
# Boots mock upstreams + the api in-process, asserts every public endpoint.
# Runs against src/code/, no docker, no network beyond loopback.
set -euo pipefail

cd "$(dirname "$0")/code"

if [ ! -d node_modules ]; then
  if [ -f package-lock.json ]; then
    echo "Installing deps (npm ci)..."
    npm ci
  else
    echo "No lockfile yet — bootstrapping with npm install (commit the resulting package-lock.json)..."
    npm install
  fi
fi

if [ ! -f tracker-dist/tracker.js ]; then
  echo "Building tracker bundle..."
  npx tsx tracker-src/build.ts
fi

exec npx tsx test.ts
