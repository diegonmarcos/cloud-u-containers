// Service definitions — fully data-driven from this container's own build-c3-services-api.json.
//
// Source-of-truth chain:
//   1. each service declares its `api` and/or `mcp` block in its own build.json
//   2. cloud-data-config-consolidated.ts merges those into _cloud-data-consolidated.json
//   3. cloud-data-config-derive.ts (deriveServiceConnections + deriveContainerConfigs)
//      stamps every peer's api/mcp into THIS container's build-c3-services-api.json
//      under .services.<name>
//   4. this loader filters that map for entries with has_api or has_mcp true
//
// At build time the file is symlinked into src/build-c3-services-api.json and copied
// into the image at /app/build-c3-services-api.json by the existing pipeline. There
// is no shared cloud-data file at runtime, no GIT_BASE volume mount.
//
// Adding a new API/MCP requires zero edits in this file — declare `api:` or `mcp:`
// in the new service's build.json and rebuild.

import { readFileSync, existsSync } from "fs";
import { join } from "path";
import type { ServiceDefinition } from "./types.js";

interface PeerEntry {
  ip: string;
  ports: Record<string, number>;
  vm: string;
  domain?: string;
  description?: string;
  api?: {
    has_api?: boolean;
    type?: ServiceDefinition["api"] extends { type: infer T } | undefined ? T : never;
    spec_path?: string;
    spec_url?: string;
    base_path?: string;
    api_path?: string | null;
    api_url?: string | null;
    endpoint_count?: number;
    display_name?: string;
    description?: string;
    auth?: string;
    healthcheck_paths?: string[];
  };
  mcp?: {
    has_mcp?: boolean;
    transport?: "stdio" | "sse" | "http" | "streamable-http";
    endpoint_path?: string;
    mcp_url?: string | null;
    tools_count?: number;
    resources_count?: number;
    prompts_count?: number;
    display_name?: string;
    description?: string;
    auth?: string;
    sdk?: string;
  };
}

interface BuildFile {
  services?: Record<string, PeerEntry>;
}

function pickPort(ports: Record<string, number> | undefined): number {
  if (!ports) return 0;
  if (typeof ports.app === "number") return ports.app;
  for (const v of Object.values(ports)) {
    if (typeof v === "number") return v;
  }
  return 0;
}

function loadRegistry(): ServiceDefinition[] {
  const candidates = [
    process.env.C3_SERVICES_BUILD_JSON,
    "/app/build-c3-services-api.json",                                              // in-image (deployed)
    join(import.meta.dirname ?? "", "../../build-c3-services-api.json"),            // dev: src/
  ].filter(Boolean) as string[];

  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try {
      const raw = JSON.parse(readFileSync(p, "utf-8")) as BuildFile;
      const out: ServiceDefinition[] = [];
      for (const [name, s] of Object.entries(raw.services ?? {})) {
        const hasApi = s.api?.has_api === true;
        const hasMcp = s.mcp?.has_mcp === true;
        if (!hasApi && !hasMcp) continue;
        const port = pickPort(s.ports);
        if (!port) continue;

        const def: ServiceDefinition = {
          name,
          displayName: s.api?.display_name ?? s.mcp?.display_name ?? name,
          description: s.description ?? s.api?.description ?? s.mcp?.description ?? "",
          vm: s.vm,
          wgIp: s.ip,
          port,
          baseUrl: `http://${s.ip}:${port}`,
          ...(s.domain ? { domain: String(s.domain).split("/")[0] } : {}),
        };

        if (hasApi && s.api) {
          def.api = {
            type: (s.api.type as any) ?? "custom-rest",
            ...(s.api.spec_url ? { specUrl: s.api.spec_url } : s.api.api_url ? { specUrl: s.api.api_url } : {}),
            ...(s.api.spec_path ? { specPath: s.api.spec_path } : {}),
            ...(s.api.base_path ? { basePath: s.api.base_path } : {}),
            endpointCount: s.api.endpoint_count ?? 0,
            description: s.api.description ?? "",
            ...(s.api.auth ? { auth: s.api.auth } : {}),
          };
        }
        if (hasMcp && s.mcp) {
          def.mcp = {
            transport: s.mcp.transport ?? "streamable-http",
            ...(s.mcp.endpoint_path ? { endpointPath: s.mcp.endpoint_path } : {}),
            toolsCount: s.mcp.tools_count ?? 0,
            resourcesCount: s.mcp.resources_count ?? 0,
            promptsCount: s.mcp.prompts_count ?? 0,
            description: s.mcp.description ?? "",
            ...(s.mcp.auth ? { auth: s.mcp.auth } : {}),
            ...(s.mcp.sdk ? { sdk: s.mcp.sdk } : {}),
          };
        }
        out.push(def);
      }
      console.error(`[definitions] loaded ${out.length} services from ${p}`);
      return out;
    } catch (e) {
      console.error(`[definitions] failed to parse ${p}:`, e);
    }
  }
  console.error("[definitions] no build-c3-services-api.json found — empty registry");
  return [];
}

export const SERVICE_DEFINITIONS: ServiceDefinition[] = loadRegistry();
