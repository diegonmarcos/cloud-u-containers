import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  assembleTopology,
  getTopologyDrift,
  getSecurityTopology,
  networkTopology,
  volumeTopology,
  imageTopology,
  dependencyTopology,
} from "../../shared/topology.js";
import { runTestSuite } from "../../shared/tests.js";
import { getConfigFile, getContainerLog, getVmStatus, getReport, getSecretsStatus } from "../../shared/files.js";
import { checkTier1All, checkTier2All, checkTier3All } from "../../shared/health.js";
import { resolveVmId } from "../../shared/config.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

function plainText(text: string): { content: { type: "text"; text: string }[] } {
  return { content: [{ type: "text" as const, text }] };
}

export function registerC3Tools(server: McpServer) {
  // ── Topology (3 tools) ──

  server.tool(
    "c3_topology",
    "Unified topology view of all VMs, services, and networks from declarative config",
    {},
    async () => jsonText("Topology", assembleTopology()),
  );

  server.tool(
    "c3_topology_drift",
    "Compare config.json with on-disk services to find drift",
    {},
    async () => jsonText("Topology drift", getTopologyDrift()),
  );

  server.tool(
    "c3_topology_security",
    "Security topology: exposed services, secrets status, VM access methods",
    {},
    async () => jsonText("Security topology", getSecurityTopology()),
  );

  // ── Tests (2 tools) ──

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

  // ── Files (4 tools) ──

  server.tool(
    "c3_file",
    "Read a service config file (build.json, docker-compose.yml, flake.nix) with secrets redacted",
    {
      service: z.string().describe("Service name"),
      file: z.enum(["build.json", "docker-compose.yml", "flake.nix"]).optional()
        .describe("File to read (default: build.json)"),
    },
    async ({ service, file }) => plainText(getConfigFile(service, file)),
  );

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

  server.tool(
    "c3_secrets_status",
    "Show secrets encryption status for services (never exposes values)",
    {
      service: z.string().optional().describe("Service name (omit for all)"),
    },
    async ({ service }) => plainText(getSecretsStatus(service)),
  );

  // ── Tiered Health (3 tools) ──

  server.tool(
    "health_tier1",
    "Quick UP check: TCP/SSH-keyscan reachability for all VMs (~2s)",
    {
      vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)"),
    },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 1 health", checkTier1All(vmId));
    },
  );

  server.tool(
    "health_tier2",
    "SSH session check: full authentication test for all VMs (~5s)",
    {
      vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)"),
    },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 2 health", checkTier2All(vmId));
    },
  );

  server.tool(
    "health_tier3",
    "Full probe: resources + docker ps for all VMs (~8s)",
    {
      vm: z.string().optional().describe("Filter by VM ID or alias (omit for all VMs)"),
    },
    async ({ vm }) => {
      const vmId = vm ? resolveVmId(vm) : undefined;
      return jsonText("Tier 3 health", checkTier3All(vmId));
    },
  );

  // ── Extended Topology (4 tools) ──

  server.tool(
    "c3_topology_network",
    "Show Docker networks per VM with connected containers",
    {},
    async () => jsonText("Network topology", networkTopology()),
  );

  server.tool(
    "c3_topology_volumes",
    "Show Docker volumes per VM",
    {},
    async () => jsonText("Volume topology", volumeTopology()),
  );

  server.tool(
    "c3_topology_images",
    "Show Docker images per VM",
    {},
    async () => jsonText("Image topology", imageTopology()),
  );

  server.tool(
    "c3_topology_dependencies",
    "Show service dependencies (depends_on from compose files)",
    {},
    async () => jsonText("Dependency topology", dependencyTopology()),
  );
}
