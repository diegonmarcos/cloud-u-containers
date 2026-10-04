#!/bin/sh
# C3 Services API entrypoint
set -e

echo "c3-services: starting API server..."
exec npx tsx src/api/index.ts
