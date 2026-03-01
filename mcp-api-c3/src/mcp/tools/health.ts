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
import {
  listServices,
  getService,
  probeSpec,
  getAllSpecs,
  serviceVersion,
  allServiceVersions,
} from "../../shared/discovery.js";
import { resolveVmId } from "../../shared/config.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

export function registerHealthTools(server: McpServer) {
  // ── Health (7 tools) ──

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

  // ── Profiling (2 tools) ──

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

  // ── Discovery (4 tools) ──

  server.tool("service_list_apis", "List all services with domain, VM, and API spec availability", {}, async () => {
    return jsonText("Service APIs", listServices());
  });

  server.tool(
    "service_get_info",
    "Get single service metadata including spec URL",
    { service: z.string().describe("Service name (e.g. authelia, matomo, photoprism)") },
    async ({ service }) => {
      const info = getService(service);
      if (!info) {
        return { content: [{ type: "text" as const, text: `Unknown service: ${service}` }], isError: true };
      }
      return jsonText(`Service info: ${service}`, info);
    },
  );

  server.tool(
    "service_get_spec",
    "Fetch the full OpenAPI/Swagger spec for a service",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      const result = probeSpec(service);
      if (!result.ok) {
        return {
          content: [{ type: "text" as const, text: `No spec available for ${service}: ${result.error}` }],
          isError: true,
        };
      }
      const text = typeof result.spec === "string" ? result.spec : JSON.stringify(result.spec, null, 2);
      const truncated = text.length > 8000 ? `...(truncated)\n${text.slice(-8000)}` : text;
      return { content: [{ type: "text" as const, text: `OpenAPI spec for ${service}:\n\n${truncated}` }] };
    },
  );

  server.tool("service_discover_all", "Parallel-fetch all service specs (cached 5min server-side)", {}, async () => {
    const result = getAllSpecs();
    const text = JSON.stringify(result, null, 2);
    const truncated = text.length > 15000 ? `...(truncated)\n${text.slice(-15000)}` : text;
    return { content: [{ type: "text" as const, text: `All service specs:\n\n${truncated}` }] };
  });

  server.tool(
    "service_version",
    "Get version info for a service (via API endpoint)",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      return jsonText(`Version: ${service}`, serviceVersion(service));
    }
  );

  server.tool("service_all_versions", "Get version info for all services", {}, async () => {
    return jsonText("All service versions", allServiceVersions());
  });

  // ── Tiered Health Checks (3 tools) ──

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

  // ── Advanced Health & Metrics (2 tools) ──

  server.tool("health_endpoints", "Probe HTTP health endpoints for all services", {}, async () => {
    return jsonText("Endpoint Health", healthEndpoints());
  });

  server.tool("metrics_snapshot", "Get current container metrics (CPU, memory, I/O)", {}, async () => {
    return jsonText("Container Metrics", metricsSnapshot());
  });

  // ── Extended Profiling (5 tools) ──

  server.tool(
    "profile_service",
    "Profile all containers for a service (by service name)",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      return jsonText(`Profile service: ${service}`, profileService(service));
    }
  );

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
      return jsonText(`Journal: ${vm}`, vmJournal(vmId, lines, unit));
    }
  );
}
