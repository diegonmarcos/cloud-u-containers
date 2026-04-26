// Service definitions — fully data-driven from cloud-data-c3-services-api.json.
//
// Source of truth: each service's build.json declares its `api` and/or `mcp` block.
// The cloud-data-config-derive engine joins those declarations with topology
// (VM wg_ip, port, domain) and emits cloud-data-c3-services-api.json.
//
// This module just LOADS that file. Adding a new API/MCP requires zero edits here.

import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import type { ServiceDefinition } from "./types.js";

interface RegistryEntry {
  vm: string;
  wg_ip: string;
  port: number;
  base_url: string;
  domain?: string;
  description?: string;
  api?: {
    type: ServiceDefinition["api"] extends infer T ? (T extends { type: infer U } ? U : never) : never;
    spec_path?: string;
    spec_url?: string;
    base_path?: string;
    endpoint_count?: number;
    display_name?: string;
    description?: string;
    auth?: string;
    has_api?: boolean;
    api_path?: string | null;
    api_url?: string | null;
    healthcheck_paths?: string[];
    internal_url?: string;
  };
  mcp?: {
    transport: "stdio" | "sse" | "http" | "streamable-http";
    endpoint_path?: string;
    tools_count?: number;
    resources_count?: number;
    prompts_count?: number;
    display_name?: string;
    description?: string;
    auth?: string;
    sdk?: string;
    has_mcp?: boolean;
    mcp_url?: string | null;
    internal_url?: string;
  };
}

interface RegistryFile {
  services: Record<string, RegistryEntry>;
}

function loadRegistry(): ServiceDefinition[] {
  // Search order: explicit override → GIT_BASE-anchored → ~/git/ fallback
  const gitBase = process.env.GIT_BASE ?? join(homedir(), "git");
  const candidates = [
    process.env.C3_SERVICES_REGISTRY_PATH,
    join(gitBase, "cloud", "2_configs", "dist", "cloud-data-c3-services-api.json"),
    join(gitBase, "cloud-data", "cloud-data-c3-services-api.json"),
  ].filter(Boolean) as string[];

  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try {
      const raw = JSON.parse(readFileSync(p, "utf-8")) as RegistryFile;
      const out: ServiceDefinition[] = [];
      for (const [name, entry] of Object.entries(raw.services ?? {})) {
        const def: ServiceDefinition = {
          name,
          displayName: entry.api?.display_name ?? entry.mcp?.display_name ?? name,
          description: entry.description ?? entry.api?.description ?? entry.mcp?.description ?? "",
          vm: entry.vm,
          wgIp: entry.wg_ip,
          port: entry.port,
          baseUrl: entry.base_url,
          ...(entry.domain ? { domain: entry.domain } : {}),
        };
        if (entry.api?.has_api) {
          def.api = {
            type: (entry.api.type as any) ?? "custom-rest",
            ...(entry.api.spec_url ? { specUrl: entry.api.spec_url } : {}),
            ...(entry.api.spec_path ? { specPath: entry.api.spec_path } : {}),
            ...(entry.api.base_path ? { basePath: entry.api.base_path } : {}),
            endpointCount: entry.api.endpoint_count ?? 0,
            description: entry.api.description ?? "",
            ...(entry.api.auth ? { auth: entry.api.auth } : {}),
          };
        }
        if (entry.mcp?.has_mcp) {
          def.mcp = {
            transport: entry.mcp.transport,
            ...(entry.mcp.endpoint_path ? { endpointPath: entry.mcp.endpoint_path } : {}),
            toolsCount: entry.mcp.tools_count ?? 0,
            resourcesCount: entry.mcp.resources_count ?? 0,
            promptsCount: entry.mcp.prompts_count ?? 0,
            description: entry.mcp.description ?? "",
            ...(entry.mcp.auth ? { auth: entry.mcp.auth } : {}),
            ...(entry.mcp.sdk ? { sdk: entry.mcp.sdk } : {}),
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
  console.error("[definitions] no cloud-data-c3-services-api.json found — empty registry");
  return [];
}

export const SERVICE_DEFINITIONS: ServiceDefinition[] = loadRegistry();
