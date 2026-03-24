// ── Security Exec — "Fix it" (4 tools) ──
// Security scanning and auditing

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { securityScan, securityDocker, securitySshKeys, securityTokens } from "../../shared/security.js";
import { resolveVmId } from "../../shared/config.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

export function registerSecurityExecTools(server: McpServer) {
  server.tool(
    "security_scan",
    "Full security scan: privileged containers, root users, exposed ports, Docker config",
    { vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Security scan results", securityScan(vmId));
    }
  );

  server.tool(
    "security_docker",
    "Docker-specific security checks: daemon config, socket permissions, capabilities",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Docker security: ${vm}`, securityDocker(vmId));
    }
  );

  server.tool(
    "security_ssh_keys",
    "Check SSH key permissions and authorized_keys configuration",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`SSH keys: ${vm}`, securitySshKeys(vmId));
    }
  );

  server.tool(
    "security_tokens",
    "Check for exposed secrets/tokens in running containers (env vars, files)",
    {},
    async () => {
      return jsonText("Token scan", securityTokens());
    }
  );
}
