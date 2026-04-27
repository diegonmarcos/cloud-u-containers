/**
 * Config tools — raw cloud-data and front-data file readers.
 * Serve the JSON/markdown source-of-truth files directly.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { getRepoRoot, getCloudDataPath } from "../../config.js";

function readJsonSafe(path: string): unknown {
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf-8"));
}

export function registerConfigTools(server: McpServer) {

  server.tool(
    "knowledge.config.topology",
    "Get cloud-data-topology.json — VMs, services, networking, full infrastructure map. The source of truth for all cloud config.",
    {},
    async () => {
      const path = getCloudDataPath("cloud-data-topology.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: `cloud-data-topology.json not found (looked at ${path})` }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  server.tool(
    "knowledge.config.configs",
    "Get cloud-data-configs.json — generated configuration for all services (domains, ports, images, routes, Caddy/Authelia/DNS config).",
    {},
    async () => {
      const path = getCloudDataPath("cloud-data-configs.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: `cloud-data-configs.json not found (looked at ${path})` }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  server.tool(
    "knowledge.config.deps",
    "Get cloud-data-deps.json — npm dependencies for all cloud services (per-service + merged). Shows what packages each service uses.",
    {},
    async () => {
      const path = getCloudDataPath("cloud-data-deps.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: `cloud-data-deps.json not found (looked at ${path})` }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  server.tool(
    "knowledge.config.topology_md",
    "Get cloud-data-topology.md — human-readable topology overview with service tables, VM assignments, and networking.",
    {},
    async () => {
      const path = getCloudDataPath("cloud-data-topology.md");
      if (!existsSync(path)) return { content: [{ type: "text" as const, text: `cloud-data-topology.md not found (looked at ${path})` }] };
      return { content: [{ type: "text" as const, text: readFileSync(path, "utf-8") }] };
    }
  );

  server.tool(
    "knowledge.config.configs_md",
    "Get cloud-data-configs.md — human-readable config overview with Caddy routes, Authelia clients, DNS zones.",
    {},
    async () => {
      const path = getCloudDataPath("cloud-data-configs.md");
      if (!existsSync(path)) return { content: [{ type: "text" as const, text: `cloud-data-configs.md not found (looked at ${path})` }] };
      return { content: [{ type: "text" as const, text: readFileSync(path, "utf-8") }] };
    }
  );

  server.tool(
    "knowledge.config.front_deps",
    "Get front-deps.json — npm dependencies for all front-end projects (per-project + merged).",
    {},
    async () => {
      const candidates = [
        join(getRepoRoot(), "front-data", "front-deps.json"),
        process.env.FRONT_DATA_PATH ? join(process.env.FRONT_DATA_PATH, "front-deps.json") : "",
      ].filter(Boolean);

      for (const path of candidates) {
        if (existsSync(path)) {
          const content = readFileSync(path, "utf-8").trim();
          if (content) return { content: [{ type: "text" as const, text: content }] };
        }
      }
      return { content: [{ type: "text" as const, text: "front-deps.json not found or empty" }] };
    }
  );
}
