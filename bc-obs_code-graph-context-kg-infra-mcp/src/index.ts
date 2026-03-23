#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerSpecTools } from "./tools/a-raw-json/specs.js";
import { registerDocsTools } from "./tools/a-raw-json/docs.js";
import { registerSkillTools } from "./tools/a-raw-json/skills.js";
import { registerOctocodeTools } from "./tools/b-octocode/octocode.js";
import { registerCodegraphTools } from "./tools/c-codegraph-rust/codegraph.js";
import { buildContextSummary } from "./context.js";

const server = new McpServer({
  name: "code-graph-context",
  version: "5.0.0",
});

// ── Resources ─────────────────────────────────────────────────────────
server.resource(
  "context-compact",
  "cloud://context/compact",
  { description: "Compact infrastructure context (~10k tokens) — VM table, service table, architecture, tool index" },
  async () => ({
    contents: [{
      uri: "cloud://context/compact",
      mimeType: "text/markdown",
      text: buildContextSummary("compact"),
    }],
  })
);

server.resource(
  "context-full",
  "cloud://context/full",
  { description: "Full infrastructure context (~50k tokens) — everything from compact + topology.md, configs.md, README, deps" },
  async () => ({
    contents: [{
      uri: "cloud://context/full",
      mimeType: "text/markdown",
      text: buildContextSummary("full"),
    }],
  })
);

// ── Section A: Raw JSON Infra Knowledge ──────────────────────────────
// 9 spec tools (topology, configs, deps, service spec, VM info, categories)
registerSpecTools(server);
// 4 doc tools (overview, service docs, README, cloud_context)
registerDocsTools(server);
// 4 skill tools (architect, frontend, debug, scraping)
registerSkillTools(server);

// ── Section B: Octocode — Semantic Code Search ───────────────────────
// 3 tools (search, memory, index)
registerOctocodeTools(server);

// ── Section C: CodeGraph-Rust — Graph Analysis (Future) ──────────────
// 3 stub tools (trace_call_path, impact_analysis, dependencies)
registerCodegraphTools(server);

const log = (msg: string) => process.stderr.write(`[code-graph-context] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting code-graph-context MCP server v5.0.0 (23 tools, 2 resources: A=17 infra, B=3 octocode, C=3 codegraph-stub)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
