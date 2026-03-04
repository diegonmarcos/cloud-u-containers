#!/bin/sh
cd "$(dirname "$0")"
set -a
eval "$(sops -d --output-type dotenv secrets.yaml 2>/dev/null)"
set +a
exec ./node_modules/.bin/tsx mcp/index.ts
