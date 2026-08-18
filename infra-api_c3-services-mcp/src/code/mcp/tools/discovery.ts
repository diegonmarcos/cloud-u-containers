/**
 * Discovery & Drift — compares the local build-c3-services-mcp.json (peer service map)
 * against what c3-services-mcp actually covers via:
 *   1. Native tool wrappers (API_META in definitions.ts)
 *   2. Proxied child MCPs (proxy-mcp.ts)
 *
 * Reports: covered, uncovered, and coverage % — so we see the gap.
 */
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

const log = (msg: string) => process.stderr.write(`[discovery] ${msg}\n`);

// ── Services with native MCP tool wrappers ──────────────────────────────
// Must match the actual tool files in tools/
const NATIVE_WRAPPED: Set<string> = new Set([
  "authelia", "scrappers-api", "dagu", "etherpad", "filebrowser",
  "gitea", "grist", "hedgedoc", "matomo", "nocodb",
  "ntfy", "ollama", "ollama-hai", "photoprism", "radicale",
  "rig-agentic-hai-1.5bq4", "rig-agentic-sonn-14bq8", "snappymail",
  "syncthing", "umami", "vaultwarden",
]);

// ── Proxied child MCP servers ───────────────────────────────────────────
const PROXIED_MCPS: Set<string> = new Set([
  "cloud-cgc-mcp", "mattermost-mcp", "mail-mcp", "google-workspace-mcp",
  "chat-mattermost",   // same Mattermost instance, covered by mattermost-mcp
]);

// ── Self (this service + siblings that ARE the MCP hub) ─────────────────
const SELF_SERVICES: Set<string> = new Set([
  "c3-services-mcp", "c3-services-api", "c3-infra-mcp", "c3-infra-api",
  "c3-diego-personal-data-mcp",
]);

// ── Infrastructure / no-API services ────────────────────────────────────
const INFRA_NO_API: Set<string> = new Set([
  "caddy", "caddy-l4-image", "hickory-dns", "introspect-proxy",
  "cloudflare", "cloudflare-worker", "redis", "postlite",
  "fluent-bit",
  "syslog-forwarder", "alerts-api", "cloud-spec",
  "backup-borg", "backup-bup",
  "photos-webhook", "orchestrator", "kg-graph",
  "code-server",       // no programmatic API
  "stalwart",          // stale — replaced by maddy
  "gcloud",            // local CLI, not a service
  "db-agent",          // internal sidecar
  "ollama-arm",        // not yet deployed (oci-apps-2 pending)
  "http-to-smtp-proxy-api",        // HTTP-to-SMTP bridge, no admin API
  "revealmd",          // static slide server, no API
]);

interface TopoService {
  vm?: string;
  domain?: string;
  port?: number;
  category?: string;
  enabled?: boolean;
  description?: string;
}

interface TopoData {
  services: Record<string, TopoService>;
}

function loadTopology(): TopoData | null {
  // c3-services-mcp reads its own build-c3-services-mcp.json (already symlinked
  // into src/ by the engine, copied into /app/ in the image via include_cloud_data).
  // The .services map is enriched with peer api/mcp metadata by deriveServiceConnections.
  // Falls back to the consolidated file (cross-cutting reads) if needed.
  const gitBase = process.env.GIT_BASE ?? join(homedir(), "git");
  const candidates = [
    "/app/build-c3-services-mcp.json",                                                            // in-image
    join(gitBase, "cloud", "1_cloud-configs", "dist", "build-c3-services-mcp.json"),                    // dev / co-located clone
    "/app/_cloud-data-consolidated.json",                                                         // in-image fallback
    join(gitBase, "cloud", "1_cloud-configs", "dist", "_cloud-data-consolidated.json"),                 // dev fallback
  ];
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try { return JSON.parse(readFileSync(p, "utf-8")) as TopoData; }
    catch { /* skip */ }
  }
  return null;
}

export function registerDiscoveryTools(server: McpServer) {
  server.tool(
    "meta.discovery.drift",
    "Compare all deployed cloud services (from build-c3-services-mcp.json) against what c3-services-mcp covers. Reports: covered (native wrapper or proxied MCP), infra (no API needed), self (MCP hub services), and UNCOVERED (the gap).",
    {},
    async () => {
      const topo = loadTopology();
      if (!topo) {
        return { content: [{ type: "text" as const, text: "ERROR: build-c3-services-mcp.json not found" }], isError: true };
      }

      const allServices = Object.keys(topo.services).sort();
      const covered: { name: string; how: string; vm?: string; domain?: string }[] = [];
      const infra: string[] = [];
      const self: string[] = [];
      const uncovered: { name: string; vm?: string; domain?: string; port?: number; category?: string }[] = [];

      for (const name of allServices) {
        const svc = topo.services[name];

        if (SELF_SERVICES.has(name)) {
          self.push(name);
        } else if (NATIVE_WRAPPED.has(name)) {
          covered.push({ name, how: "native-wrapper", vm: svc.vm, domain: svc.domain });
        } else if (PROXIED_MCPS.has(name)) {
          covered.push({ name, how: "proxied-mcp", vm: svc.vm, domain: svc.domain });
        } else if (INFRA_NO_API.has(name)) {
          infra.push(name);
        } else {
          uncovered.push({
            name,
            vm: svc.vm,
            domain: svc.domain,
            port: svc.port,
            category: svc.category,
          });
        }
      }

      const total = allServices.length;
      const coveredCount = covered.length + self.length;
      const pct = total > 0 ? Math.round((coveredCount / (total - infra.length)) * 100) : 0;

      const report = {
        summary: {
          total_services: total,
          covered: covered.length,
          proxied_mcps: covered.filter(c => c.how === "proxied-mcp").length,
          native_wrappers: covered.filter(c => c.how === "native-wrapper").length,
          self_hub: self.length,
          infra_no_api: infra.length,
          uncovered: uncovered.length,
          coverage_pct: `${pct}%`,
        },
        uncovered,
        covered,
        self,
        infra_no_api: infra,
      };

      return { content: [{ type: "text" as const, text: JSON.stringify(report, null, 2) }] };
    }
  );
}
