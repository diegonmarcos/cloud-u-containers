import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { registry } from "../../registry/index.js";

export function registerRegistryTools(server: McpServer) {
  server.tool(
    "services_list",
    "List all services with their API status, type, and endpoint count",
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
    "services_info",
    "Get detailed information about a specific service",
    { service: z.string().describe("Service name (e.g. matomo, syncthing)") },
    async ({ service }) => {
      const svc = registry.get(service);
      if (!svc) {
        return { content: [{ type: "text" as const, text: `Service '${service}' not found` }], isError: true };
      }
      return { content: [{ type: "text" as const, text: JSON.stringify(svc, null, 2) }] };
    }
  );

  server.tool(
    "services_spec",
    "Fetch the OpenAPI spec for a service (if available)",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      const svc = registry.get(service);
      if (!svc) {
        return { content: [{ type: "text" as const, text: `Service '${service}' not found` }], isError: true };
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
}
