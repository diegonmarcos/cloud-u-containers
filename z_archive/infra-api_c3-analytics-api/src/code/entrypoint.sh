#!/bin/sh
# C3 Analytics API entrypoint
set -e
exec npx tsx api/index.ts
