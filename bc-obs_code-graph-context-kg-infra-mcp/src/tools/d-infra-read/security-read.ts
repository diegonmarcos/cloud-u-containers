// ── Security READ tools (extracted from c3-infra-mcp security.ts) ──
// Security topology and secrets status (read-only, no SSH exec)

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync } from "fs";
import { getConfigPath } from "../../shared/paths.js";
import { getSecretsStatus } from "../../shared/files.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

function plainText(text: string): { content: { type: "text"; text: string }[] } {
  return { content: [{ type: "text" as const, text }] };
}

export function registerSecurityReadTools(server: McpServer) {
  server.tool(
    "c3_topology_security",
    "Security topology: exposed services, secrets status, VM access methods",
    {},
    async () => {
      const topo = JSON.parse(readFileSync(getConfigPath(), "utf-8"));
      const exposed = Object.entries(topo.services as Record<string, any>)
        .filter(([, s]) => (s as any).domain)
        .map(([name, s]: [string, any]) => ({ name, domain: s.domain, vm: s.vm }));
      return jsonText("Security topology", { exposedServices: exposed, wireguard: topo.wireguard, firewalls: topo.firewalls, os_firewalls: topo.os_firewalls });
    },
  );

  server.tool(
    "c3_secrets_status",
    "Show secrets encryption status for services (never exposes values)",
    {
      service: z.string().optional().describe("Service name (omit for all)"),
    },
    async ({ service }) => plainText(getSecretsStatus(service)),
  );
}
