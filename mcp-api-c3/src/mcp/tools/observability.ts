// ── Observability Pillar — "How it's doing" (33 tools) ──
// Health, profiling, diagnostics, tests, alerts, notifications, DB

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
  sendNotification,
  alertHealthDown,
  alertHealthRecovered,
  alertCertExpiring,
  alertDiskFull,
} from "../../shared/notify.js";
import {
  getHealthHistory,
  getUptimeReport,
  getAuditLog,
  getDeployHistory,
  getAlertState,
  updateAlertState,
  pruneOldRecords,
} from "../../shared/db.js";
import { resolveVmId } from "../../shared/config.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

function plainText(text: string): { content: { type: "text"; text: string }[] } {
  return { content: [{ type: "text" as const, text }] };
}

export function registerObservabilityTools(server: McpServer) {
  // ── Health (10 tools, from health.ts) ──

  server.tool("health_alive", "Check if the API is alive (heartbeat)", {}, async () => {
    return jsonText("Health: OK", healthAlive());
  });

  server.tool("health_declared", "List config-declared services (instant, no network probing)", {}, async () => {
    return jsonText("Declared services", healthDeclared());
  });

  server.tool(
    "health_deployed",
    "List live deployed containers on VMs (probes via SSH/Docker)",
    { vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Deployed containers", healthDeployed(vmId));
    },
  );

  server.tool("health_drift", "Show drift between declared config and deployed containers", {}, async () => {
    return jsonText("Config drift", healthDrift());
  });

  server.tool(
    "health_status",
    "Full health dashboard — declared + deployed + drift combined",
    { vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Health status", healthStatus(vmId));
    },
  );

  server.tool(
    "health_tier1",
    "Quick UP check: TCP/SSH-keyscan reachability for all VMs (~2s)",
    { vm: z.string().optional().describe("Filter by VM ID or alias") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 1 Health", checkTier1All(vmId));
    }
  );

  server.tool(
    "health_tier2",
    "SSH session check: full authentication test for all VMs (~5s)",
    { vm: z.string().optional().describe("Filter by VM ID or alias") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 2 Health", checkTier2All(vmId));
    }
  );

  server.tool(
    "health_tier3",
    "Full probe: resources + docker ps for all VMs (~8s)",
    { vm: z.string().optional().describe("Filter by VM ID or alias") },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 3 Health", checkTier3All(vmId));
    }
  );

  server.tool("health_endpoints", "Probe HTTP health endpoints for all services", {}, async () => {
    return jsonText("Endpoint Health", healthEndpoints());
  });

  server.tool("metrics_snapshot", "Get current container metrics (CPU, memory, I/O)", {}, async () => {
    return jsonText("Container Metrics", metricsSnapshot());
  });

  // ── Profiling (3 tools, from health.ts) ──

  server.tool(
    "profile_container",
    "Run diagnostic profile: CPU, memory, network, disk, ports, health, processes, uptime",
    { container: z.string().describe("Container name to profile") },
    async ({ container }) => {
      return jsonText(`Profile ${container}`, profileContainer(container));
    },
  );

  server.tool(
    "profile_vm",
    "Batch profile all containers on a VM",
    { vm: z.string().describe("VM ID or alias to profile") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Profile VM ${vm}`, profileVm(vmId));
    },
  );

  server.tool(
    "profile_service",
    "Profile all containers for a service (by service name)",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      return jsonText(`Profile service: ${service}`, profileService(service));
    }
  );

  // ── VM Diagnostics (4 tools, from health.ts) ──

  server.tool(
    "vm_network",
    "Show network configuration for a VM (interfaces, routes, WireGuard)",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Network: ${vm}`, vmNetwork(vmId));
    }
  );

  server.tool(
    "vm_top",
    "Show top processes on a VM",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Top: ${vm}`, vmTop(vmId));
    }
  );

  server.tool(
    "vm_disk_usage",
    "Show disk usage breakdown on a VM (du -sh per directory)",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      const vmId = resolveVmId(vm);
      return jsonText(`Disk usage: ${vm}`, vmDiskUsage(vmId));
    }
  );

  server.tool(
    "vm_journal",
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

  // ── Tests (1 tool, from c3.ts) ──

  server.tool(
    "c3_test",
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

  // ── VM Status & Reports (2 tools, from c3.ts) ──

  server.tool(
    "c3_vm_status",
    "Get combined VM status: uptime, WireGuard, docker ps, disk, memory",
    {
      vm: z.string().describe("VM ID or SSH alias"),
    },
    async ({ vm }) => plainText(getVmStatus(vm)),
  );

  server.tool(
    "c3_report",
    "Generate a text report (health, services, drift, resources, security)",
    {
      type: z.enum(["health", "services", "drift", "resources", "security"]).describe("Report type"),
    },
    async ({ type }) => plainText(getReport(type)),
  );

  // ── Notifications (5 tools, from notify.ts) ──

  server.tool(
    "notify_send",
    "Send a push notification via ntfy.sh",
    {
      title: z.string().describe("Notification title"),
      message: z.string().describe("Notification message"),
      priority: z.enum(["min", "low", "default", "high", "urgent"]).optional().describe("Priority level (default: default)"),
      tags: z.array(z.string()).optional().describe("Tags (e.g. ['warning', 'cloud'])"),
    },
    async ({ title, message, priority, tags }) => {
      const result = sendNotification({ title, message, priority, tags });
      return {
        content: [{ type: "text", text: result.ok ? "Notification sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_health_down",
    "Send alert for a VM/service going down",
    {
      target: z.string().describe("VM or service name"),
      details: z.string().optional().describe("Additional details"),
    },
    async ({ target, details }) => {
      const result = alertHealthDown(target, details ?? "");
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${(result as any).error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_health_recovered",
    "Send alert for a VM/service recovery",
    {
      target: z.string().describe("VM or service name"),
    },
    async ({ target }) => {
      const result = alertHealthRecovered(target);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_cert_expiring",
    "Send alert for expiring TLS certificate",
    {
      domain: z.string().describe("Domain with expiring cert"),
      daysRemaining: z.number().describe("Days until expiration"),
    },
    async ({ domain, daysRemaining }) => {
      const result = alertCertExpiring(domain, daysRemaining);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "notify_disk_full",
    "Send alert for disk space warning",
    {
      vm: z.string().describe("VM ID or alias"),
      percent: z.string().describe("Disk usage percentage"),
    },
    async ({ vm, percent }) => {
      const result = alertDiskFull(vm, percent);
      return {
        content: [{ type: "text", text: result.ok ? "Alert sent" : `Error: ${result.error}` }],
        isError: !result.ok,
      };
    }
  );

  // ── Database (7 tools, from database.ts) ──

  server.tool(
    "db_health_history",
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
    "db_uptime_report",
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
    "db_audit_log",
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
    "db_deploy_history",
    "Get deployment history for a service",
    {
      service: z.string().optional().describe("Service name (omit for all)"),
      limit: z.number().optional().describe("Max records (default: 50)"),
    },
    async ({ service, limit }) => {
      return jsonText(`Deploy history${service ? `: ${service}` : ""}`, getDeployHistory({ service, limit }));
    }
  );

  server.tool(
    "db_alert_state",
    "Get current alert state for a VM",
    { vm: z.string().describe("VM ID or alias") },
    async ({ vm }) => {
      return jsonText(`Alert state: ${vm}`, getAlertState(vm));
    }
  );

  server.tool(
    "db_alert_update",
    "Update alert state for a VM",
    {
      vm: z.string().describe("VM ID or alias"),
      status: z.string().describe("Current status (e.g. 'up', 'down')"),
      notified: z.boolean().describe("Has notification been sent?"),
    },
    async ({ vm, status, notified }) => {
      updateAlertState(vm, status, notified);
      return { content: [{ type: "text", text: `Alert state updated: ${vm} → ${status} (notified=${notified})` }] };
    }
  );

  server.tool(
    "db_prune",
    "Remove old records from SQLite database (keeps last N days)",
    { days: z.number().optional().describe("Keep last N days (default: 30)") },
    async ({ days }) => {
      const result = pruneOldRecords(days);
      return { content: [{ type: "text", text: `Pruned ${result.healthDeleted + result.auditDeleted + result.deployDeleted} old records (health: ${result.healthDeleted}, audit: ${result.auditDeleted}, deploy: ${result.deployDeleted})` }] };
    }
  );
}
