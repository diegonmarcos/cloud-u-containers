import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { rawHttpRequest } from "../../shared/http.js";

// Data-driven Dagu endpoint resolution (env override → topology → fallback).
// Reads services.dagu.{ip,ports.app,api.base_path} from the same build-c3-services-mcp.json
// this MCP already consumes (see discovery.ts loadTopology), falling back to the
// consolidated file. NEVER hardcode the IP — dagu runs on oci-apps (10.0.0.6:8070),
// and a stale 10.0.0.3 default silently pointed every dagu tool at the wrong VM.
function resolveDagu(): { base: string; path: string } {
  const envBase = process.env.DAGU_API_URL;
  const envPath = process.env.DAGU_API_PATH;
  const gitBase = process.env.GIT_BASE ?? join(homedir(), "git");
  const candidates = [
    "/app/build-c3-services-mcp.json",
    join(gitBase, "cloud", "9_others", "dist", "build-c3-services-mcp.json"),
    "/app/_cloud-data-consolidated.json",
    join(gitBase, "cloud", "9_others", "dist", "_cloud-data-consolidated.json"),
  ];
  let base = "";
  let path = "";
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try {
      const d = JSON.parse(readFileSync(p, "utf-8"));
      const svc = d.services?.dagu;
      if (!svc) continue;
      const ip = svc.ip ?? (svc.vm ? d.vms?.[svc.vm]?.wg_ip : undefined);
      const port = svc.ports?.app ?? svc.port;
      if (ip && port) base = `http://${ip}:${port}`;
      const bp = svc.api?.base_path;
      if (typeof bp === "string" && bp.startsWith("/")) path = bp;
      if (base) break;
    } catch { /* skip */ }
  }
  // `||` (not `??`) so an empty-string unresolved base/path falls through to the default.
  return {
    base: envBase || base || "http://10.0.0.6:8070",
    path: envPath || path || "/api/v1",
  };
}

const { base: DAGU_BASE, path: DAGU_PATH } = resolveDagu();
const DAGU_AUTH = process.env.DAGU_BASIC_AUTH ?? "";

function daguHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};
  if (DAGU_AUTH) {
    headers["Authorization"] = `Basic ${Buffer.from(DAGU_AUTH).toString("base64")}`;
  }
  return headers;
}

export function registerDaguTools(server: McpServer) {
  server.tool(
    "infra.dagu.list",
    "List available Dagu DAG workflows",
    {},
    async () => {
      const result = rawHttpRequest("GET", `${DAGU_BASE}${DAGU_PATH}/dags`, undefined, 10000, daguHeaders());
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    "infra.dagu.trigger",
    "Trigger a Dagu DAG workflow by name",
    {
      dag_id: z.string().describe("DAG ID or name to trigger"),
      params: z.string().optional().describe("Optional parameters as key=value pairs"),
    },
    async ({ dag_id, params }) => {
      // Dagu v1 run endpoint is POST /dags/{name}/start. Hardcoding /api/v2 hit the
      // SPA (HTTP 200 HTML) so triggers reported success but did nothing — path is
      // now data-driven (DAGU_PATH from services.dagu.api.base_path).
      const body = params ? JSON.stringify({ params }) : undefined;
      const result = rawHttpRequest("POST", `${DAGU_BASE}${DAGU_PATH}/dags/${dag_id}/start`, body, 15000, daguHeaders());
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );
}
