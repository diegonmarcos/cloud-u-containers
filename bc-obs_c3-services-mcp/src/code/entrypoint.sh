#!/bin/sh
# C3 Services MCP entrypoint
set -e
exec npx tsx mcp/http.ts
