/**
 * MCP Proxy — connects as MCP CLIENT to child MCP servers (mattermost-mcp,
 * mail-mcp, google-workspace-mcp, code-graph-context) and re-exposes
 * their tools under this hub server.
 *
 * Zero code duplication: child MCPs are the source of truth for their tools.
 * If a child adds a new tool, it appears here automatically on next session.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

const log = (msg: string) => process.stderr.write(`[proxy-mcp] ${msg}\n`);

interface ChildMcp {
  name: string;
  url: string;
}

const CHILD_MCPS: ChildMcp[] = [
  { name: "mattermost-mcp", url: "http://mattermost-mcp:3102/mcp" },
  { name: "mail-mcp", url: "http://mail-mcp:3103/mcp" },
  { name: "google-workspace-mcp", url: "http://google-workspace-mcp:8000/mcp" },
  { name: "code-graph-context", url: "http://code-graph-context:3105/mcp" },
];

export async function registerProxiedTools(server: McpServer): Promise<void> {
  for (const child of CHILD_MCPS) {
    try {
      const transport = new StreamableHTTPClientTransport(new URL(child.url));
      const client = new Client(
        { name: "c3-services-proxy", version: "1.0.0" },
        { capabilities: {} }
      );

      await client.connect(transport);
      const { tools } = await client.listTools();
      log(`${child.name}: discovered ${tools.length} tools`);

      for (const tool of tools) {
        // Re-register each child tool under this server
        // inputSchema from listTools is a JSON Schema object
        const schema = (tool.inputSchema?.properties ?? {}) as Record<string, unknown>;

        server.tool(
          tool.name,
          tool.description ?? `[${child.name}] ${tool.name}`,
          schema,
          async (args) => {
            const result = await client.callTool({
              name: tool.name,
              arguments: args,
            });
            return result as { content: Array<{ type: "text"; text: string }> };
          }
        );
      }

      log(`${child.name}: registered ${tools.length} proxied tools`);
    } catch (err) {
      log(`${child.name}: failed to connect (${err}) — skipping`);
    }
  }
}
