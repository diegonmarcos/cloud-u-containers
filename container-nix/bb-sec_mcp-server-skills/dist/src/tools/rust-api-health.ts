import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rustApiGet } from "../utils/http.js";

function formatResult(label: string, result: ReturnType<typeof rustApiGet>) {
  if (!result.ok) {
    return {
      content: [{ type: "text" as const, text: `${label}: FAILED (HTTP ${result.status})\n${result.error ?? ""}\n${result.raw}` }],
      isError: true,
    };
  }
  const text = typeof result.data === "string" ? result.data : JSON.stringify(result.data, null, 2);
  return {
    content: [{ type: "text" as const, text: `${label}: OK\n\n${text}` }],
  };
}

export function registerRustApiHealthTools(server: McpServer) {
  // ── Health (7 tools) ──

  server.tool(
    "health_alive",
    "Check if the Rust API is alive (heartbeat)",
    {},
    async () => {
      // 10s: simple heartbeat should respond within seconds
      const result = rustApiGet("/api/health", 10_000);
      return formatResult("Rust API health", result);
    }
  );

  server.tool(
    "health_declared",
    "List config-declared services (instant, no network probing)",
    {},
    async () => {
      const result = rustApiGet("/api/health/declared");
      return formatResult("Declared services", result);
    }
  );

  server.tool(
    "health_deployed",
    "List live deployed containers on VMs (probes via SSH/Docker)",
    {
      vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)"),
    },
    async ({ vm }) => {
      const endpoint = vm ? `/api/health/deployed/${encodeURIComponent(vm)}` : "/api/health/deployed";
      // 60s: probes all VMs via SSH + docker ps, can be slow across 4 VMs
      const result = rustApiGet(endpoint, 60_000);
      return formatResult("Deployed containers", result);
    }
  );

  server.tool(
    "health_drift",
    "Show drift between declared config and deployed containers",
    {},
    async () => {
      const result = rustApiGet("/api/health/drift", 60_000);
      return formatResult("Config drift", result);
    }
  );

  server.tool(
    "health_status",
    "Full health dashboard — declared + deployed + drift combined",
    {
      vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)"),
    },
    async ({ vm }) => {
      const endpoint = vm ? `/api/health/status/${encodeURIComponent(vm)}` : "/api/health/status";
      const result = rustApiGet(endpoint, 60_000);
      return formatResult("Health status", result);
    }
  );

  server.tool(
    "profile_container",
    "Run diagnostic profile: CPU, memory, network, disk, ports, health, processes, uptime",
    {
      container: z.string().describe("Container name to profile"),
    },
    async ({ container }) => {
      // 30s: runs 8 diagnostic checks sequentially inside the container
      const result = rustApiGet(`/api/profiling/${encodeURIComponent(container)}`, 30_000);
      return formatResult(`Profile ${container}`, result);
    }
  );

  server.tool(
    "profile_vm",
    "Batch profile all containers on a VM",
    {
      vm: z.string().describe("VM ID or alias to profile"),
    },
    async ({ vm }) => {
      // 60s: profiles every container on the VM, 8 checks each
      const result = rustApiGet(`/api/profiling/vm/${encodeURIComponent(vm)}`, 60_000);
      return formatResult(`Profile VM ${vm}`, result);
    }
  );

  // ── Discovery (4 tools) ──

  server.tool(
    "service_list_apis",
    "List all services with domain, VM, and API spec availability",
    {},
    async () => {
      const result = rustApiGet("/api/services");
      return formatResult("Service APIs", result);
    }
  );

  server.tool(
    "service_get_info",
    "Get single service metadata including spec URL",
    {
      service: z.string().describe("Service name (e.g. authelia, matomo, photoprism)"),
    },
    async ({ service }) => {
      const result = rustApiGet(`/api/services/${encodeURIComponent(service)}`);
      return formatResult(`Service info: ${service}`, result);
    }
  );

  server.tool(
    "service_get_spec",
    "Fetch the full OpenAPI/Swagger spec for a service",
    {
      service: z.string().describe("Service name"),
    },
    async ({ service }) => {
      const result = rustApiGet(`/api/services/${encodeURIComponent(service)}/spec`, 30_000);
      if (!result.ok) {
        return {
          content: [{ type: "text" as const, text: `No spec available for ${service}: ${result.error ?? "unknown error"}\n${result.raw}` }],
          isError: true,
        };
      }
      const text = typeof result.data === "string" ? result.data : JSON.stringify(result.data, null, 2);
      // Truncate large specs to last 8000 chars
      const truncated = text.length > 8000 ? `...(truncated)\n${text.slice(-8000)}` : text;
      return {
        content: [{ type: "text" as const, text: `OpenAPI spec for ${service}:\n\n${truncated}` }],
      };
    }
  );

  server.tool(
    "service_discover_all",
    "Parallel-fetch all service specs (cached 5min server-side)",
    {},
    async () => {
      const result = rustApiGet("/api/services/all/specs", 60_000);
      if (!result.ok) {
        return formatResult("Service discovery", result);
      }
      const text = typeof result.data === "string" ? result.data : JSON.stringify(result.data, null, 2);
      // Truncate very large payloads
      const truncated = text.length > 15000 ? `...(truncated)\n${text.slice(-15000)}` : text;
      return {
        content: [{ type: "text" as const, text: `All service specs:\n\n${truncated}` }],
      };
    }
  );
}
