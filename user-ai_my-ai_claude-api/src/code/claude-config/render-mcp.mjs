#!/usr/bin/env node
// Render the HTTP MCP server list into ~/.claude.json, preserving the existing
// login/config. Token comes from $AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN. Run on every
// container boot (the claude_home volume persists ~/.claude.json across restarts).
//
// Testable: pass a template path as argv[2] and set HOME to a scratch dir.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const TPL = process.argv[2] || "/app/claude-config/mcp.tpl.json";
const token = process.env.AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN || "";
if (!token) {
  console.error("[render-mcp] AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN unset; skipping MCP");
  process.exit(0);
}

const claudeJson = join(process.env.HOME || ".", ".claude.json");
const servers = JSON.parse(
  readFileSync(TPL, "utf8").replaceAll("${AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN}", token),
);

let cfg = {};
if (existsSync(claudeJson)) {
  try {
    cfg = JSON.parse(readFileSync(claudeJson, "utf8"));
  } catch {
    console.error("[render-mcp] existing ~/.claude.json unparseable; starting fresh");
    cfg = {};
  }
}
cfg.mcpServers = servers; // replace only mcpServers; login + all other keys preserved
writeFileSync(claudeJson, JSON.stringify(cfg, null, 2));
console.error(`[render-mcp] wrote ${Object.keys(servers).length} MCP servers to ${claudeJson}`);
