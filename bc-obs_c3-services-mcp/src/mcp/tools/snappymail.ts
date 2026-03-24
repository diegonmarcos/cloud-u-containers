import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { rawHttpRequest } from "../../shared/http.js";

const SNAPPYMAIL_BASE = "http://10.0.0.3:8888";

function snappyGet(path: string): string {
  const result = rawHttpRequest("GET", `${SNAPPYMAIL_BASE}${path}`, undefined, 10_000);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status, raw: result.raw?.slice(0, 500) }, null, 2);
}

export function registerSnappymailTools(server: McpServer) {
  server.tool(
    "snappymail-health",
    "Check SnappyMail webmail health (HTTP status + version)",
    {},
    async () => {
      const result = rawHttpRequest("GET", `${SNAPPYMAIL_BASE}/`, undefined, 10_000);
      const version = result.raw?.match(/snappymail\/v\/([\d.]+)/)?.[1] ?? "unknown";
      const status = { healthy: result.ok, status: result.status, version };
      return { content: [{ type: "text" as const, text: JSON.stringify(status, null, 2) }] };
    }
  );

  server.tool(
    "snappymail-domains",
    "List configured mail domains in SnappyMail (reads domain config from container)",
    {},
    async () => {
      // SnappyMail stores domain configs as .ini files in the container
      // We use docker exec to list them since there's no REST API
      const { spawnSync } = await import("node:child_process");
      const proc = spawnSync("ssh", ["oci-mail", "docker exec snappymail find /var/lib/snappymail/_data_/_default_/domains -name '*.ini' -exec basename {} \\;"], {
        timeout: 10_000, encoding: "utf-8",
      });
      const domains = (proc.stdout ?? "").trim().split("\n").filter(Boolean).map(f => f.replace(".ini", ""));
      return { content: [{ type: "text" as const, text: JSON.stringify({ domains }, null, 2) }] };
    }
  );

  server.tool(
    "snappymail-domain_config",
    "Read SnappyMail domain configuration (IMAP/SMTP settings)",
    {},
    async () => {
      const { spawnSync } = await import("node:child_process");
      const proc = spawnSync("ssh", ["oci-mail", "docker exec snappymail cat /var/lib/snappymail/_data_/_default_/domains/diegonmarcos.com.ini"], {
        timeout: 10_000, encoding: "utf-8",
      });
      return { content: [{ type: "text" as const, text: proc.stdout?.trim() || proc.stderr || "no config found" }] };
    }
  );
}
