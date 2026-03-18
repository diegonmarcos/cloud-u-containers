/**
 * Data tools — expose cloud-data/ and front-data/ JSON files.
 * These are the generated data artifacts from the C3 engine.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { getRepoRoot } from "../config.js";

function readJsonSafe(path: string): unknown {
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf-8"));
}

export function registerDataTools(server: McpServer) {

  // ── Cloud Topology ──────────────────────────────────────────────────
  server.tool(
    "c3_topology",
    "Get cloud-topology.json — VMs, services, networking, full infrastructure map. The source of truth for all cloud config.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-topology.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: "cloud-topology.json not found" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  // ── Cloud Configs ───────────────────────────────────────────────────
  server.tool(
    "c3_configs",
    "Get cloud-configs.json — generated configuration for all services (domains, ports, images, routes, Caddy/Authelia/DNS config).",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-configs.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: "cloud-configs.json not found" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  // ── Cloud Deps ──────────────────────────────────────────────────────
  server.tool(
    "c3_deps",
    "Get cloud-deps.json — npm dependencies for all cloud services (per-service + merged). Shows what packages each service uses.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-deps.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: "cloud-deps.json not found" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  // ── Cloud Topology Markdown ─────────────────────────────────────────
  server.tool(
    "c3_topology_md",
    "Get cloud-topology.md — human-readable topology overview with service tables, VM assignments, and networking.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-topology.md");
      if (!existsSync(path)) return { content: [{ type: "text" as const, text: "cloud-topology.md not found" }] };
      return { content: [{ type: "text" as const, text: readFileSync(path, "utf-8") }] };
    }
  );

  // ── Cloud Configs Markdown ──────────────────────────────────────────
  server.tool(
    "c3_configs_md",
    "Get cloud-configs.md — human-readable config overview with Caddy routes, Authelia clients, DNS zones.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-configs.md");
      if (!existsSync(path)) return { content: [{ type: "text" as const, text: "cloud-configs.md not found" }] };
      return { content: [{ type: "text" as const, text: readFileSync(path, "utf-8") }] };
    }
  );

  // ── Front Deps ──────────────────────────────────────────────────────
  server.tool(
    "c3_deps_front",
    "Get front-deps.json — npm dependencies for all front-end projects (per-project + merged).",
    {},
    async () => {
      // front-data/ can be a submodule or at FRONT_DATA_PATH
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
