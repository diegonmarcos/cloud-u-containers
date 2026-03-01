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
} from "../../shared/health.js";
import { profileContainer, profileVm } from "../../shared/diagnostics.js";
import { listServices, getService, probeSpec, getAllSpecs } from "../../shared/discovery.js";
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
}
