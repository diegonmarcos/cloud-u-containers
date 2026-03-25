// ── Security Exec — 7 tools ──
// Security scanning and auditing

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync } from "fs";
import { securityScan, securityDocker, securitySshKeys, securityTokens } from "../../shared/security.js";
import { resolveVmId, getConfig } from "../../shared/config.js";
import { getConfigPath } from "../../shared/paths.js";
import { getSecretsStatus } from "../../shared/files.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

function plainText(text: string): { content: { type: "text"; text: string }[] } {
  return { content: [{ type: "text" as const, text }] };
}

export function registerSecurityExecTools(server: McpServer) {
  // ── security: Full security audit across all VMs ──
  server.tool(
    "security",
    "Full security audit: runs scan + docker + ssh_keys + tokens across all VMs",
    {},
    async () => {
      const config = getConfig();
      const vmIds = Object.keys(config.vms);
      const sections: string[] = [];

      // 1. Global scan
      const scanResult = securityScan();
      sections.push(`SECURITY SCAN (all VMs)\n${"─".repeat(60)}\n${typeof scanResult === "string" ? scanResult : JSON.stringify(scanResult, null, 2)}`);

      // 2. Docker security per VM
      for (const vmId of vmIds) {
        try {
          const result = securityDocker(vmId);
          sections.push(`\nDOCKER SECURITY: ${vmId}\n${"─".repeat(60)}\n${typeof result === "string" ? result : JSON.stringify(result, null, 2)}`);
        } catch (e) { sections.push(`\nDOCKER SECURITY: ${vmId} — FAILED: ${e}`); }
      }

      // 3. SSH keys per VM
      for (const vmId of vmIds) {
        try {
          const result = securitySshKeys(vmId);
          sections.push(`\nSSH KEYS: ${vmId}\n${"─".repeat(60)}\n${typeof result === "string" ? result : JSON.stringify(result, null, 2)}`);
        } catch (e) { sections.push(`\nSSH KEYS: ${vmId} — FAILED: ${e}`); }
      }

      // 4. Token scan
      const tokenResult = securityTokens();
      sections.push(`\nTOKEN SCAN\n${"─".repeat(60)}\n${typeof tokenResult === "string" ? tokenResult : JSON.stringify(tokenResult, null, 2)}`);

      return { content: [{ type: "text" as const, text: sections.join("\n\n") }] };
    }
  );

  server.tool(
    "security-scan",
    "Full security scan: privileged containers, root users, exposed ports, Docker config",
    { vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Security scan results", securityScan(vmId));
    }
  );

  server.tool(
    "security-docker",
    "Docker-specific security checks: daemon config, socket permissions, capabilities",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Docker security: ${vm}`, securityDocker(vmId));
    }
  );

  server.tool(
    "security-ssh_keys",
    "Check SSH key permissions and authorized_keys configuration",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`SSH keys: ${vm}`, securitySshKeys(vmId));
    }
  );

  server.tool(
    "security-tokens",
    "Check for exposed secrets/tokens in running containers (env vars, files)",
    {},
    async () => {
      return jsonText("Token scan", securityTokens());
    }
  );

  // ── Security READ tools (moved from cloud-cgc-mcp) ──

  server.tool(
    "cloud-data-security_topology",
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
    "cloud-data-secrets_status",
    "Show secrets encryption status for services (never exposes values)",
    {
      service: z.string().optional().describe("Service name (omit for all)"),
    },
    async ({ service }) => plainText(getSecretsStatus(service)),
  );
}
