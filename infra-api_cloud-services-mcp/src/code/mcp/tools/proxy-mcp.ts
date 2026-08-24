/**
 * MCP Proxy — connects as MCP CLIENT to child MCP servers and re-exposes
 * their tools under this hub server.
 *
 * Data flow (no hardcoded URLs):
 *   build.json .proxied_mcps.{infra,user}[]  → flake.nix resolves via
 *   cloud-data {ip,ports}                    → PROXIED_MCPS env var (JSON)
 *   → this module parses it at import time.
 *
 * Resilience invariants (see build.json .proxied_mcps.retry):
 *   - Per-child exponential backoff (initial → max).
 *   - Bounded retry-state LRU (max_retry_state_entries) so the Map can
 *     never grow beyond declared children. This closes the OOM leak
 *     (H1 root cause: unbounded retry-state + orphaned setInterval timers
 *     across session re-creates).
 *   - Failed client/transport are closed even on connect throw, so
 *     Node doesn't leak AbortControllers / sockets.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

const log = (msg: string) => process.stderr.write(`[proxy-mcp] ${msg}\n`);

// ── Config (data-driven from build.json via PROXIED_MCPS env var) ────

interface ChildMcp { name: string; url: string; }
interface RetryCfg {
  initial_ms: number;
  max_ms: number;
  max_retry_state_entries: number;
}
interface ProxiedMcpsCfg {
  infra: ChildMcp[];
  user: ChildMcp[];
  retry: RetryCfg;
}

// Defaults match previous behaviour if PROXIED_MCPS is unset (dev/test).
const DEFAULT_CFG: ProxiedMcpsCfg = {
  infra: [],
  user: [],
  retry: { initial_ms: 10_000, max_ms: 120_000, max_retry_state_entries: 32 },
};

function loadConfig(): ProxiedMcpsCfg {
  const raw = process.env.PROXIED_MCPS;
  if (!raw) {
    log("PROXIED_MCPS env var not set — no child MCPs will be proxied");
    return DEFAULT_CFG;
  }
  try {
    const parsed = JSON.parse(raw) as Partial<ProxiedMcpsCfg>;
    return {
      infra: parsed.infra ?? [],
      user: parsed.user ?? [],
      retry: {
        initial_ms: parsed.retry?.initial_ms ?? DEFAULT_CFG.retry.initial_ms,
        max_ms: parsed.retry?.max_ms ?? DEFAULT_CFG.retry.max_ms,
        max_retry_state_entries:
          parsed.retry?.max_retry_state_entries ?? DEFAULT_CFG.retry.max_retry_state_entries,
      },
    };
  } catch (err) {
    log(`PROXIED_MCPS JSON parse failed: ${err} — falling back to defaults`);
    return DEFAULT_CFG;
  }
}

const CFG: ProxiedMcpsCfg = loadConfig();
const INFRA_MCPS: ChildMcp[] = CFG.infra;
const USER_MCPS: ChildMcp[] = CFG.user;

log(
  `config: infra=[${INFRA_MCPS.map((c) => c.name).join(",")}] ` +
    `user=[${USER_MCPS.map((c) => c.name).join(",")}] ` +
    `retry(initial=${CFG.retry.initial_ms}ms,max=${CFG.retry.max_ms}ms,cap=${CFG.retry.max_retry_state_entries})`,
);

// ── Bounded retry state (LRU) ────────────────────────────────────────
//
// Map#set preserves insertion order; on hit we delete+reinsert to move the
// key to the tail. When size exceeds max, we evict from the head.
// Guarantees: size <= max_retry_state_entries AT ALL TIMES, even if
// callers mistakenly schedule retries for unknown children.

interface RetryEntry { nextAttempt: number; intervalMs: number; }
const retryState = new Map<string, RetryEntry>();

function touchRetryEntry(name: string, entry: RetryEntry): void {
  if (retryState.has(name)) retryState.delete(name);
  retryState.set(name, entry);
  while (retryState.size > CFG.retry.max_retry_state_entries) {
    // Evict oldest (Map iteration is insertion order).
    const oldestKey = retryState.keys().next().value;
    if (oldestKey === undefined) break;
    retryState.delete(oldestKey);
    log(`retry-state LRU evicted ${oldestKey} (cap=${CFG.retry.max_retry_state_entries})`);
  }
}

// ── Connected-children tracking ──────────────────────────────────────
export const connectedChildren = new Set<string>();

// Single-timer guard: http.ts recreates the MCP server on every client
// `initialize`, but we MUST NOT spawn a new setInterval on each recreate
// — that was the other half of the OOM leak.
let retryTimer: ReturnType<typeof setInterval> | null = null;

// Remember the live server so the retry loop can re-register tools on
// late-connect even after a session swap.
let activeServer: McpServer | null = null;

export async function registerProxiedInfraTools(server: McpServer): Promise<void> {
  activeServer = server;
  await connectChildren(server, INFRA_MCPS);
}

export async function registerProxiedUserTools(server: McpServer): Promise<void> {
  activeServer = server;
  await connectChildren(server, USER_MCPS);
}

/** @deprecated Use registerProxiedInfraTools + registerProxiedUserTools */
export async function registerProxiedTools(server: McpServer): Promise<void> {
  activeServer = server;
  await connectChildren(server, [...INFRA_MCPS, ...USER_MCPS]);
}

/** Start background retry loop for any children that failed initial connect.
 *  Idempotent — safe to call on every session recreate. */
export function startProxyRetryLoop(server: McpServer): void {
  activeServer = server;

  // Initialise per-child retry state (bounded).
  for (const c of [...INFRA_MCPS, ...USER_MCPS]) {
    if (!retryState.has(c.name)) {
      touchRetryEntry(c.name, { nextAttempt: 0, intervalMs: CFG.retry.initial_ms });
    }
  }

  // Guard against multiple intervals — critical to avoid timer leak across
  // session recreates (http.ts calls us on every client `initialize`).
  if (retryTimer !== null) return;

  retryTimer = setInterval(async () => {
    const srv = activeServer;
    if (!srv) return;

    const now = Date.now();
    const all = [...INFRA_MCPS, ...USER_MCPS];
    const pending = all.filter((c) => !connectedChildren.has(c.name));
    if (pending.length === 0) return;

    for (const child of pending) {
      const state = retryState.get(child.name);
      if (!state || now < state.nextAttempt) continue;

      try {
        await connectChild(srv, child);
        log(`${child.name}: late-connected — sending tools/list_changed`);
        srv.sendToolListChanged();
        touchRetryEntry(child.name, { nextAttempt: 0, intervalMs: CFG.retry.initial_ms });
      } catch {
        const nextInterval = Math.min(state.intervalMs * 2, CFG.retry.max_ms);
        touchRetryEntry(child.name, {
          nextAttempt: now + state.intervalMs,
          intervalMs: nextInterval,
        });
      }
    }
  }, CFG.retry.initial_ms);
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
    // AbortControllers into the container's memory cgroup.
    await client.close().catch(() => { /* ignore — already bad state */ });
    await transport.close().catch(() => { /* ignore */ });
    throw err;
  }
  const { tools } = await client.listTools();
  log(`${child.name}: discovered ${tools.length} tools at ${child.url}`);

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
