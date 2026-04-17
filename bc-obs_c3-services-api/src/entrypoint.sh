#!/bin/sh
# C3 Services API entrypoint
set -e
exec npx tsx src/api/index.ts
