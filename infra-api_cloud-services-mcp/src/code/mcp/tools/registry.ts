import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { registry } from "../../registry/index.js";
import { searchPublicRegistry, getPublicServer } from "../../registry/public-registry.js";

export function registerRegistryTools(server: McpServer) {
  server.tool(
    "meta.registry.services_list",
    "List all local services (Diego's cloud infra) with their API status, type, and endpoint count. These are deployed and accessible via WireGuard mesh.",
    {},
    async () => {
      const services = registry.list().map((s) => ({
        name: s.name,
        displayName: s.displayName,
        description: s.description,
        vm: s.vm,
        apiType: s.api.type,
        endpointCount: s.api.endpointCount,
        hasSpec: !!s.api.specUrl,
      }));
      return { content: [{ type: "text" as const, text: JSON.stringify({ services, total: services.length }, null, 2) }] };
    }
  );

  server.tool(
    "meta.registry.services_info",
    "Get detailed information about a specific service. Checks local registry first, then falls back to the public MCP registry (registry.modelcontextprotocol.io) if not found locally.",
    { service: z.string().describe("Service name (e.g. matomo, syncthing, or a public MCP name like 'filesystem')") },
    async ({ service }) => {
      // Try local first
      const svc = registry.get(service);
      if (svc) {
        return { content: [{ type: "text" as const, text: JSON.stringify({ source: "local", ...svc }, null, 2) }] };
      }

      // Fallback: search public registry
      const publicResult = searchPublicRegistry(service, 5);
      if (publicResult.servers.length > 0) {
        return {
          content: [{
            type: "text" as const,
            text: JSON.stringify({
              source: "public-registry",
              note: `'${service}' not found in local infrastructure. Found ${publicResult.total} match(es) in the public MCP registry (registry.modelcontextprotocol.io):`,
              servers: publicResult.servers,
            }, null, 2),
          }],
        };
      }

      return { content: [{ type: "text" as const, text: `Service '${service}' not found in local infrastructure or public MCP registry.` }], isError: true };
    }
  );

  server.tool(
    "meta.registry.services_spec",
    "Fetch the OpenAPI spec for a local service (if available)",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      const svc = registry.get(service);
      if (!svc) {
        return { content: [{ type: "text" as const, text: `Service '${service}' not found locally. Use registry-mcp_search to find public MCP servers.` }], isError: true };
      }
      if (!svc.api.specUrl) {
        return { content: [{ type: "text" as const, text: `Service '${service}' has no OpenAPI spec URL` }], isError: true };
      }
      const spec = await registry.fetchSpec(service);
      if (!spec) {
        return { content: [{ type: "text" as const, text: "Failed to fetch spec" }], isError: true };
      }
      return { content: [{ type: "text" as const, text: JSON.stringify(spec, null, 2) }] };
    }
  );

  // ── Public MCP Registry — search gateway ─────────────────────────
  server.tool(
    "meta.registry.mcp_search",
    "Search the public MCP registry (registry.modelcontextprotocol.io) for MCP servers by keyword. Use when a capability is not available in the local infrastructure. Returns server names, descriptions, tools, and install instructions.",
    { query: z.string().describe("Search keyword (e.g. 'google drive', 'slack', 'github', 'database')"), limit: z.number().optional().describe("Max results (default 10)") },
    async ({ query, limit }) => {
      const result = searchPublicRegistry(query, limit ?? 10);
      if (result.servers.length === 0) {
        return { content: [{ type: "text" as const, text: `No MCP servers found for '${query}' in registry.modelcontextprotocol.io` }] };
      }

      const formatted = result.servers.map((s) => {
        const toolList = s.tools?.map((t) => `    - ${t.name}: ${t.description ?? ""}`).join("\n") ?? "    (tools not listed)";
        const source = s.source?.repo ? `github.com/${s.source.owner}/${s.source.repo}` : s.source?.url ?? "unknown";
        return `## ${s.name}\n${s.description}\n- **Version**: ${s.version ?? "latest"}\n- **Source**: ${source}\n- **Tools**:\n${toolList}`;
      });

      return {
        content: [{
          type: "text" as const,
          text: `# Public MCP Registry — "${query}" (${result.total} results)\n\n${formatted.join("\n\n---\n\n")}`,
        }],
      };
    }
  );

  server.tool(
    "meta.registry.mcp_get",
    "Get full details for a specific server from the public MCP registry, including all tools, source, and version info.",
    { name: z.string().describe("Full server name (e.g. 'io.github.user/server-name')"), version: z.string().optional().describe("Version (default: 'latest')") },
    async ({ name, version }) => {
      const server_info = getPublicServer(name, version ?? "latest");
      if (!server_info) {
        return { content: [{ type: "text" as const, text: `Server '${name}' not found in public registry` }], isError: true };
      }
      return { content: [{ type: "text" as const, text: JSON.stringify(server_info, null, 2) }] };
    }
  );
}
