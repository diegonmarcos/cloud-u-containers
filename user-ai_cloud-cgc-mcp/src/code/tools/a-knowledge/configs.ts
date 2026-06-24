/**
 * Config tools — raw cloud-data and front-data file readers.
 * Serve the JSON/markdown source-of-truth files directly.
 *
 * 2026-04-27 migrated: cloud-data-{topology,configs,deps}.json -> _cloud-data-consolidated.json[.{configs,deps}]
 * All three legacy split files are now slices of `_cloud-data-consolidated.json`:
 *   - topology shape  -> consolidated top-level (consolidated IS a superset of topology)
 *   - configs slice   -> consolidated.configs
 *   - deps slice      -> consolidated.deps
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { getRepoRoot, getCloudDataPath } from "../../config.js";

function readJsonSafe(path: string): unknown {
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf-8"));
}

function readConsolidated(): any {
  const path = getCloudDataPath("_cloud-data-consolidated.json");
  return readJsonSafe(path);
}

export function registerConfigTools(server: McpServer) {

  server.tool(
    "knowledge.config.topology",
    "Get _cloud-data-consolidated.json — VMs, services, networking, full infrastructure map. The source of truth for all cloud config.",
    {},
    async () => {
      // 2026-04-27 migrated: cloud-data-topology.json -> _cloud-data-consolidated.json (top-level)
      const path = getCloudDataPath("_cloud-data-consolidated.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: `_cloud-data-consolidated.json not found (looked at ${path})` }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  server.tool(
    "knowledge.config.configs",
    "Get _cloud-data-consolidated.json[.configs] — generated configuration for all services (domains, ports, images, routes, Caddy/Authelia/DNS config).",
    {},
    async () => {
      // 2026-04-27 migrated: cloud-data-configs.json -> _cloud-data-consolidated.json.configs
      const consolidated = readConsolidated();
      if (!consolidated) {
        const path = getCloudDataPath("_cloud-data-consolidated.json");
        return { content: [{ type: "text" as const, text: `_cloud-data-consolidated.json not found (looked at ${path})` }] };
      }
      const slice = consolidated.configs;
      if (slice == null) return { content: [{ type: "text" as const, text: ".configs slice not present in _cloud-data-consolidated.json" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(slice, null, 2) }] };
    }
  );

  server.tool(
    "knowledge.config.deps",
    "Get _cloud-data-consolidated.json[.deps] — npm dependencies for all cloud services (per-service + merged). Shows what packages each service uses.",
    {},
    async () => {
      // 2026-04-27 migrated: cloud-data-deps.json -> _cloud-data-consolidated.json.deps
      const consolidated = readConsolidated();
      if (!consolidated) {
        const path = getCloudDataPath("_cloud-data-consolidated.json");
        return { content: [{ type: "text" as const, text: `_cloud-data-consolidated.json not found (looked at ${path})` }] };
      }
      const slice = consolidated.deps;
      if (slice == null) return { content: [{ type: "text" as const, text: ".deps slice not present in _cloud-data-consolidated.json" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(slice, null, 2) }] };
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
