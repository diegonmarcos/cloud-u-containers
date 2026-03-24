#!/bin/sh
# C3 Services MCP entrypoint
set -e
exec npx tsx src/mcp/http.ts
