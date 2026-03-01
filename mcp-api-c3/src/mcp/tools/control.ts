import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  vmStart,
  vmStop,
  vmReset,
  containerStart,
  containerStop,
  containerRestart,
  serviceStart,
  serviceStop,
} from "../../shared/control.js";

function formatControl(result: { ok: boolean; message: string }) {
  return {
    content: [{ type: "text" as const, text: result.message }],
    isError: !result.ok,
  };
}

export function registerControlTools(server: McpServer) {
  // ── VM Control (3 tools) ──

  server.tool(
    "vm_start",
    "Start a VM via the Rust API (handles OCI/GCP abstraction)",
    { vm: z.string().describe("VM ID or SSH alias") },
    async ({ vm }) => formatControl(vmStart(vm)),
  );

  server.tool(
    "vm_stop",
    "Stop a VM gracefully via the Rust API",
    { vm: z.string().describe("VM ID or SSH alias") },
    async ({ vm }) => formatControl(vmStop(vm)),
  );

  server.tool(
    "vm_reset",
    "Reset/force-restart a VM via the Rust API",
    { vm: z.string().describe("VM ID or SSH alias") },
    async ({ vm }) => formatControl(vmReset(vm)),
  );

  // ── Container Control (3 tools) ──

  server.tool(
    "container_start",
    "Start a container via the Rust API (preferred — handles VM auto-wake and validation).",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => formatControl(containerStart(vm, name)),
  );

  server.tool(
    "container_stop",
    "Stop a container on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => formatControl(containerStop(vm, name)),
  );

  server.tool(
    "container_restart",
    "Restart a container on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      name: z.string().describe("Container name"),
    },
    async ({ vm, name }) => formatControl(containerRestart(vm, name)),
  );

  // ── Service Control (2 tools) ──

  server.tool(
    "service_start",
    "Start all containers for a service on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name"),
    },
    async ({ vm, service }) => formatControl(serviceStart(vm, service)),
  );

  server.tool(
    "service_stop",
    "Stop all containers for a service on a VM",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name"),
    },
    async ({ vm, service }) => formatControl(serviceStop(vm, service)),
  );
}
