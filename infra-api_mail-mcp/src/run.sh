#!/bin/sh
cd "$(dirname "$0")"
# Decrypt sops -> JSON -> filter top-level "_"-prefix keys (human-reference
# _credentials metadata must stay out of env) -> export remaining KEY=VALUE
set -a
eval "$(
  sops -d --output-type json secrets.yaml 2>/dev/null \
    | jq -r 'to_entries[] | select(.key | startswith("_") | not) |
        "\(.key)=\(.value | tostring | @sh)"'
)"
set +a
exec ./node_modules/.bin/tsx mcp/index.ts
