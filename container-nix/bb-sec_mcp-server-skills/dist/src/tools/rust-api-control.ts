import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rustApiPost } from "../utils/http.js";
import { audit } from "../utils/audit.js";

function formatResult(label: string, result: ReturnType<typeof rustApiPost>) {
  const text = typeof result.data === "string" ? result.data : JSON.stringify(result.data, null, 2);
  if (!result.ok) {
    return {
      content: [{ type: "text" as const, text: `${label}: FAILED (HTTP ${result.status})\n${result.error ?? ""}\n${result.raw}` }],
      isError: true,
    };
  }
  return {
    content: [{ type: "text" as const, text: `${label}: OK\n\n${text}` }],
  };
}

export function registerRustApiControlTools(server: McpServer) {
  // ── VM Control (3 tools) ──

  server.tool(
    "vm_start",
    "Start a VM via the Rust API (handles OCI/GCP abstraction)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
    },
    async ({ vm }) => {
      const result = rustApiPost(`/api/vms/${encodeURIComponent(vm)}/start`, undefined, 60_000);
      audit("vm_start", vm, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`VM start ${vm}`, result);
    }
  );

  server.tool(
    "vm_stop",
    "Stop a VM gracefully via the Rust API",
    {
      vm: z.string().describe("VM ID or SSH alias"),
    },
    async ({ vm }) => {
      const result = rustApiPost(`/api/vms/${encodeURIComponent(vm)}/stop`, undefined, 60_000);
      audit("vm_stop", vm, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`VM stop ${vm}`, result);
    }
  );

  server.tool(
    "vm_reset",
    "Reset/force-restart a VM via the Rust API",
    {
      vm: z.string().describe("VM ID or SSH alias"),
    },
    async ({ vm }) => {
      const result = rustApiPost(`/api/vms/${encodeURIComponent(vm)}/reset`, undefined, 60_000);
      audit("vm_reset", vm, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`VM reset ${vm}`, result);
    }
  );

  // ── Container Control (3 tools) ──

  server.tool(
    "container_start",
    "Start a container via the Rust API (preferred — handles VM auto-wake and validation).",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => {
      const result = rustApiPost(
        `/api/vms/${encodeURIComponent(vm)}/containers/${encodeURIComponent(name)}/start`,
        undefined,
        60_000
      );
      audit("container_start", `${name}@${vm}`, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`Container start ${name}@${vm}`, result);
    }
  );

  server.tool(
    "container_stop",
    "Stop a container on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => {
      const result = rustApiPost(
        `/api/vms/${encodeURIComponent(vm)}/containers/${encodeURIComponent(name)}/stop`,
        undefined,
        30_000
      );
      audit("container_stop", `${name}@${vm}`, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`Container stop ${name}@${vm}`, result);
    }
  );

  server.tool(
    "container_restart",
    "Restart a container on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => {
      const result = rustApiPost(
        `/api/vms/${encodeURIComponent(vm)}/containers/${encodeURIComponent(name)}/restart`,
        undefined,
        60_000
      );
      audit("container_restart", `${name}@${vm}`, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`Container restart ${name}@${vm}`, result);
    }
  );

  // ── Service Control (2 tools) ──

  server.tool(
    "service_start",
    "Start all containers for a service on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name"),
    },
    async ({ vm, service }) => {
      const result = rustApiPost(
        `/api/vms/${encodeURIComponent(vm)}/services/${encodeURIComponent(service)}/start`,
        undefined,
        120_000
      );
      audit("service_start", `${service}@${vm}`, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`Service start ${service}@${vm}`, result);
    }
  );

  server.tool(
    "service_stop",
    "Stop all containers for a service on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name"),
    },
    async ({ vm, service }) => {
      const result = rustApiPost(
        `/api/vms/${encodeURIComponent(vm)}/services/${encodeURIComponent(service)}/stop`,
        undefined,
        60_000
      );
      audit("service_stop", `${service}@${vm}`, result.ok ? "OK" : `FAILED (HTTP ${result.status})`);
      return formatResult(`Service stop ${service}@${vm}`, result);
    }
  );
}
