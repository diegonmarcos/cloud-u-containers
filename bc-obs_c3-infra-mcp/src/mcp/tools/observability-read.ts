// ── Observability READ tools (extracted from c3-infra-mcp observability.ts) ──
// Health, profiling, diagnostics, tests, reports, DB queries (read-only)

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  healthAlive,
  healthDeclared,
  healthDeployed,
  healthDrift,
  healthStatus,
  checkTier1All,
  checkTier2All,
  checkTier3All,
  healthEndpoints,
  metricsSnapshot,
} from "../../shared/health.js";
import {
  profileContainer,
  profileVm,
  profileService,
  vmNetwork,
  vmTop,
  vmDiskUsage,
  vmJournal,
} from "../../shared/diagnostics.js";
import { runTestSuite } from "../../shared/tests.js";
import { getVmStatus, getReport } from "../../shared/files.js";
import {
  getHealthHistory,
  getUptimeReport,
  getAuditLog,
  getDeployHistory,
} from "../../shared/db.js";
import { resolveVmId } from "../../shared/config.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

function plainText(text: string): { content: { type: "text"; text: string }[] } {
  return { content: [{ type: "text" as const, text }] };
}

export function registerObservabilityReadTools(server: McpServer) {
  // ── Health (10 tools) ──

  server.tool("obs.data.health_alive", "Check if the API is alive (heartbeat)", {}, async () => {
    return jsonText("Health: OK", healthAlive());
  });

  server.tool("obs.data.health_declared", "List config-declared services (instant, no network probing)", {}, async () => {
    return jsonText("Declared services", healthDeclared());
  });

  server.tool(
    "obs.data.health_deployed",
    "List live deployed containers on VMs (probes via SSH/Docker)",
    { vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Deployed containers", healthDeployed(vmId));
    },
  );

  server.tool("obs.data.health_drift", "Show drift between declared config and deployed containers", {}, async () => {
    return jsonText("Config drift", healthDrift());
  });

  server.tool(
    "obs.data.health_status",
    "Full health dashboard — declared + deployed + drift combined",
    { vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Health status", healthStatus(vmId));
    },
  );

  server.tool(
    "obs.data.health_tier1",
    "Quick UP check: TCP/SSH-keyscan reachability for all VMs (~2s)",
    { vm: z.string().optional().describe("Filter by VM ID or alias") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 1 Health", checkTier1All(vmId));
    }
  );

  server.tool(
    "obs.data.health_tier2",
    "SSH session check: full authentication test for all VMs (~5s)",
    { vm: z.string().optional().describe("Filter by VM ID or alias") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 2 Health", checkTier2All(vmId));
    }
  );

  server.tool(
    "obs.data.health_tier3",
    "Full probe: resources + docker ps for all VMs (~8s)",
    { vm: z.string().optional().describe("Filter by VM ID or alias") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 3 Health", checkTier3All(vmId));
    }
  );

  server.tool("obs.data.health_endpoints", "Probe HTTP health endpoints for all services", {}, async () => {
    return jsonText("Endpoint Health", healthEndpoints());
  });

  server.tool("obs.data.metrics", "Get current container metrics (CPU, memory, I/O)", {}, async () => {
    return jsonText("Container Metrics", metricsSnapshot());
  });

  // ── Profiling (3 tools) ──

  server.tool(
    "obs.data.profile_container",
    "Run diagnostic profile: CPU, memory, network, disk, ports, health, processes, uptime",
    { container: z.string().describe("Container name to profile") },
    async ({ container }) => {
      return jsonText(`Profile ${container}`, profileContainer(container));
    },
  );

  server.tool(
    "obs.data.profile_vm",
    "Batch profile all containers on a VM",
    { vm: z.string().describe("VM ID or alias to profile") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Profile VM ${vm}`, profileVm(vmId));
    },
  );

  server.tool(
    "obs.data.profile_service",
    "Profile all containers for a service (by service name)",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      return jsonText(`Profile service: ${service}`, profileService(service));
    }
  );

  // ── VM Diagnostics (4 tools) ──

  server.tool(
    "obs.data.vm_network",
    "Show network configuration for a VM (interfaces, routes, WireGuard)",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Network: ${vm}`, vmNetwork(vmId));
    }
  );

  server.tool(
    "obs.data.vm_top",
    "Show top processes on a VM",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Top: ${vm}`, vmTop(vmId));
    }
  );

  server.tool(
    "obs.data.vm_disk",
    "Show disk usage breakdown on a VM (du -sh per directory)",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Disk usage: ${vm}`, vmDiskUsage(vmId));
    }
  );

  server.tool(
    "obs.data.vm_journal",
    "Get recent systemd journal logs from a VM",
    {
      vm: z.string().describe("VM ID or alias"),
      lines: z.number().optional().describe("Number of lines (default: 100)"),
      unit: z.string().optional().describe("Filter by systemd unit (e.g. 'docker')"),
    },
    async ({ vm, lines, unit }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Journal: ${vm}`, vmJournal(vmId, lines as any, unit as any));
    }
  );

  // ── Tests (1 tool) ──

  server.tool(
    "obs.data.test",
    "Run an infrastructure test suite to validate the cloud is working",
    {
      suite: z.enum([
        "connectivity",
        "dns",
        "tls",
        "routes",
        "containers",
        "wireguard",
        "auth",
        "secrets",
        "compose",
        "volumes",
        "resources",
        "latency",
        "images",
        "cross-vm",
        "full",
      ]).describe("Test suite to run"),
      target: z.string().optional().describe("Optional target (VM ID/alias for connectivity/containers, domain for dns/tls/routes)"),
    },
    async ({ suite, target }) => jsonText(`Test suite: ${suite}`, runTestSuite(suite, target)),
  );

  // ── VM Status & Reports (2 tools) ──

  server.tool(
    "obs.data.vm_status",
    "Get combined VM status: uptime, WireGuard, docker ps, disk, memory",
    {
      vm: z.string().describe("VM ID or SSH alias"),
    },
    async ({ vm }) => plainText(getVmStatus(vm)),
  );

  server.tool(
    "obs.data.report",
    "Generate a text report (health, services, drift, resources, security)",
    {
      type: z.enum(["health", "services", "drift", "resources", "security"]).describe("Report type"),
    },
    async ({ type }) => plainText(getReport(type)),
  );

  // ── Database READ (4 tools) ──

  server.tool(
    "obs.data.db_health_history",
    "Get health check history for a VM (last N checks from SQLite)",
    {
      vm: z.string().describe("VM ID or alias"),
      limit: z.number().optional().describe("Max records (default: 100)"),
    },
    async ({ vm, limit }) => {
      return jsonText(`Health history: ${vm}`, getHealthHistory({ vm, limit }));
    }
  );

  server.tool(
    "obs.data.db_uptime",
    "Get uptime statistics for a VM over a time period",
    {
      vm: z.string().describe("VM ID or alias"),
      days: z.number().optional().describe("Days back (default: 7)"),
    },
    async ({ vm, days }) => {
      const hours = days ? days * 24 : 24 * 7;
      return jsonText(`Uptime report: ${vm}`, getUptimeReport(vm, hours));
    }
  );

  server.tool(
    "obs.data.db_audit",
    "Get audit log entries (all mutating operations)",
    {
      tool: z.string().optional().describe("Filter by tool name"),
      target: z.string().optional().describe("Filter by target"),
      limit: z.number().optional().describe("Max records (default: 100)"),
    },
    async ({ tool, target, limit }) => {
      return jsonText("Audit log", getAuditLog({ tool, limit }));
    }
  );

  server.tool(
    "obs.data.db_deploy",
    "Get deployment history for a service",
    {
      service: z.string().optional().describe("Service name (omit for all)"),
      limit: z.number().optional().describe("Max records (default: 50)"),
    },
    async ({ service, limit }) => {
      return jsonText(`Deploy history${service ? `: ${service}` : ""}`, getDeployHistory({ service, limit }));
    }
  );
}
