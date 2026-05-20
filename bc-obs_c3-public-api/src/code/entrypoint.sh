#!/bin/sh
# C3 Public API entrypoint — start Fastify directly via tsx.
set -e
exec npx tsx api/index.ts
