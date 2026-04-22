/**
 * MCP Proxy — connects as MCP CLIENT to child MCP servers and re-exposes
 * their tools under this hub server.
 *
 * Truly persistent: retries failed children in background, sends
 * tools/list_changed notification so Claude Code refreshes automatically.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

const log = (msg: string) => process.stderr.write(`[proxy-mcp] ${msg}\n`);

// Exponential backoff — start at 10s, double each failure, cap at 2 min.
// Without backoff, a persistently-down child retried every 30s over ~75 min
// accumulated enough transport client state inside a 512 MiB container to
// trigger Node OOM (SIGABRT 134). See T2.1 in the health-errors plan.
const RETRY_INITIAL_MS = 10_000;
const RETRY_MAX_MS = 120_000;

interface ChildMcp {
  name: string;
  url: string;
}

// Per-child exponential backoff state.
const retryState = new Map<string, { nextAttempt: number; intervalMs: number }>();

// ── INFRA proxied MCPs ──────────────────────────
// All containers use host network — no Docker DNS, use localhost
const INFRA_MCPS: ChildMcp[] = [
  { name: "cloud-cgc-mcp", url: "http://127.0.0.1:3105/mcp" },
];

// ── USER proxied MCPs ──────────────────────────
const USER_MCPS: ChildMcp[] = [
  { name: "mattermost-mcp", url: "http://127.0.0.1:3102/mcp" },
  { name: "mail-mcp", url: "http://127.0.0.1:3103/mcp" },
  { name: "google-workspace-mcp", url: "http://127.0.0.1:3104/mcp" },
];

// Track which children are connected so we don't re-register
export const connectedChildren = new Set<string>();

export async function registerProxiedInfraTools(server: McpServer): Promise<void> {
  await connectChildren(server, INFRA_MCPS);
}

export async function registerProxiedUserTools(server: McpServer): Promise<void> {
  await connectChildren(server, USER_MCPS);
}

/** @deprecated Use registerProxiedInfraTools + registerProxiedUserTools */
export async function registerProxiedTools(server: McpServer): Promise<void> {
  await connectChildren(server, [...INFRA_MCPS, ...USER_MCPS]);
}

/** Start background retry loop for any children that failed initial connect.
 *  Per-child exponential backoff (10s → 2 min cap) prevents transport-client
 *  accumulation under persistent upstream failure (H1 OOM root cause). */
export function startProxyRetryLoop(server: McpServer): void {
  const allChildren = [...INFRA_MCPS, ...USER_MCPS];

  // Initialise per-child state.
  for (const c of allChildren) {
    retryState.set(c.name, { nextAttempt: 0, intervalMs: RETRY_INITIAL_MS });
  }

  // Tick at the minimum retry cadence; each child is only attempted when its
  // own backoff deadline has elapsed.
  setInterval(async () => {
    const now = Date.now();
    const pending = allChildren.filter((c) => !connectedChildren.has(c.name));
    if (pending.length === 0) return;

    for (const child of pending) {
      const state = retryState.get(child.name)!;
      if (now < state.nextAttempt) continue;

      try {
        await connectChild(server, child);
        log(`${child.name}: late-connected — sending tools/list_changed`);
        server.sendToolListChanged();
        // success — reset backoff for any future disconnect cycle.
        state.intervalMs = RETRY_INITIAL_MS;
        state.nextAttempt = 0;
      } catch {
        // schedule the next attempt using exponential backoff.
        state.nextAttempt = now + state.intervalMs;
        state.intervalMs = Math.min(state.intervalMs * 2, RETRY_MAX_MS);
      }
    }
  }, RETRY_INITIAL_MS);
}

// ── Internals ────────────────────────────────────────────────────────

async function connectChildren(server: McpServer, children: ChildMcp[]): Promise<void> {
  for (const child of children) {
    try {
      await connectChild(server, child);
    } catch (err) {
      log(`${child.name}: failed to connect (${err}) — will retry in background`);
    }
  }
}

async function connectChild(server: McpServer, child: ChildMcp): Promise<void> {
  if (connectedChildren.has(child.name)) return;

  const transport = new StreamableHTTPClientTransport(new URL(child.url));
  const client = new Client(
    { name: "c3-services-proxy", version: "1.0.0" },
    { capabilities: {} },
  );

  try {
    await client.connect(transport);
  } catch (err) {
    // Close transport + client on failure so retries don't leak sockets /
    // AbortControllers into the container's 1 GiB cgroup — root cause of H1.
    await client.close().catch(() => { /* ignore — already bad state */ });
    await transport.close().catch(() => { /* ignore */ });
    throw err;
  }
  const { tools } = await client.listTools();
  log(`${child.name}: discovered ${tools.length} tools`);

  for (const tool of tools) {
    const zodShape = jsonSchemaToZod(tool.inputSchema);

    server.tool(
      tool.name,
      tool.description ?? `[${child.name}] ${tool.name}`,
      zodShape,
      async (args) => {
        const result = await client.callTool({
          name: tool.name,
          arguments: args,
        });
        return result as { content: Array<{ type: "text"; text: string }> };
      },
    );
  }

  connectedChildren.add(child.name);
  log(`${child.name}: registered ${tools.length} proxied tools`);
}

/** Convert JSON Schema inputSchema to Zod shape for server.tool() */
function jsonSchemaToZod(inputSchema?: { properties?: Record<string, any>; required?: string[] }): Record<string, z.ZodTypeAny> {
  const props = (inputSchema?.properties ?? {}) as Record<string, any>;
  const required = new Set(inputSchema?.required ?? []);
  const zodShape: Record<string, z.ZodTypeAny> = {};

  for (const [key, prop] of Object.entries(props)) {
    let field: z.ZodTypeAny;
    switch (prop.type) {
      case "number": case "integer": field = z.number(); break;
      case "boolean": field = z.boolean(); break;
      case "array": field = z.array(z.any()); break;
      default: field = z.string(); break;
    }
    if (prop.description) field = field.describe(prop.description);
    if (!required.has(key)) field = field.optional();
    zodShape[key] = field;
  }

  return zodShape;
}
