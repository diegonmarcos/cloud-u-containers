/**
 * Single tool registry -> ONE dispatcher tool.
 *
 * registerTools() keeps calling `server.tool(name, desc, shape, handler)` exactly
 * as before; it is handed a ToolRegistry instead of the real McpServer, which
 * records each definition. From that registry we derive:
 *   - `superapp`  {method: enum, params: object}, one short line per method
 *   - `superapp_help({method})`  full description + JSON schema of one method
 *   - (MCP_LEGACY_TOOLS=1 only) the old superapp_* registrations, unchanged.
 *     Deprecated: remove after 2026-11-22 (30 days).
 * Pattern: cloud-u-containers 76a73e9 (cloud-infra-mcp).
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z, type ZodRawShape } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";

export const TOOL = "superapp";
export const HELP = "superapp_help";
const PREFIX = "superapp_";

export interface ToolDef {
  name: string; // original name, e.g. "superapp_logcat_full"
  description: string;
  shape: ZodRawShape | undefined;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  handler: (...a: any[]) => any;
}

export class ToolRegistry {
  readonly defs = new Map<string, ToolDef>();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  tool(name: string, ...rest: any[]): void {
    const handler = rest.pop();
    let description = "";
    let shape: ZodRawShape | undefined;
    if (typeof rest[0] === "string") description = rest.shift();
    if (rest[0] && typeof rest[0] === "object") shape = rest.shift();
    if (this.defs.has(name)) throw new Error(`duplicate tool: ${name}`);
    this.defs.set(name, { name, description, shape, handler });
  }
}

export interface Method { method: string; def: ToolDef }

/** "superapp_logcat_full" -> "logcat_full". */
export function methodsOf(reg: ToolRegistry): Method[] {
  const out: Method[] = [];
  const seen = new Set<string>();
  for (const def of reg.defs.values()) {
    if (!def.name.startsWith(PREFIX)) throw new Error(`unclassifiable tool name: ${def.name}`);
    const method = def.name.slice(PREFIX.length);
    if (seen.has(method)) throw new Error(`method collision: ${method}`);
    seen.add(method);
    out.push({ method, def });
  }
  return out;
}

/** <= 5 words of the first clause of the existing description (trailing stopwords trimmed). */
export function summary(desc: string): string {
  const first = desc.split(/\s[—–-]\s|:\s|\.\s|\s\(|\n/)[0].trim();
  const w = first.split(/\s+/).slice(0, 5);
  while (w.length > 1 && /^(the|a|an|to|of|for|on|via|and|or|in|from|with|by|is|that|as|if|at|one|any)$/i.test(w[w.length - 1])) w.pop();
  return w.join(" ").replace(/[,;:]+$/, "");
}

const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] });
const errText = (t: string) => ({ content: [{ type: "text" as const, text: t }], isError: true as const });

export function validateParams(m: Method, params: unknown): { ok: true; value: unknown } | { ok: false; error: string } {
  const r = z.object(m.def.shape ?? {}).strict().safeParse(params ?? {});
  if (r.success) return { ok: true, value: r.data };
  const issues = r.error.issues.map((i) => `${i.path.join(".") || "(params)"}: ${i.message}`).join("; ");
  return { ok: false, error: `Invalid params for ${TOOL}.${m.method}: ${issues}. Call ${HELP} {method:"${m.method}"} for the schema.` };
}

export function jsonSchemaOf(def: ToolDef): unknown {
  return zodToJsonSchema(z.object(def.shape ?? {}).strict(), { $refStrategy: "none" });
}

export function registerGrouped(server: McpServer, reg: ToolRegistry): Method[] {
  const all = methodsOf(reg);
  const byName = new Map(all.map((m) => [m.method, m]));
  const names = all.map((m) => m.method) as [string, ...string[]];
  const lines = all.map((m) => `${m.method}: ${summary(m.def.description)}`);
  server.tool(
    TOOL,
    `Android constellation debug API + shell door; params: see ${HELP}\n${lines.join("\n")}`,
    { method: z.enum(names), params: z.record(z.unknown()).optional() },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (async (args: { method: string; params?: Record<string, unknown> }, extra: unknown) => {
      const m = byName.get(args.method);
      if (!m) return errText(`Unknown method ${args.method} in ${TOOL}`);
      const v = validateParams(m, args.params);
      if (!v.ok) return errText(v.error);
      return m.def.shape ? m.def.handler(v.value, extra) : m.def.handler(extra);
    }) as any,
  );

  server.tool(HELP, `Full doc+schema of one method, e.g. logcat_full`, { method: z.string() }, async ({ method }: { method: string }) => {
    const bare = method.replace(/^superapp[_.]/, "");
    const m = byName.get(bare);
    if (!m) {
      const near = all.filter((x) => x.method.includes(bare) || bare.includes(x.method)).slice(0, 10).map((x) => x.method);
      return errText(`Unknown method "${method}". ${near.length ? "Did you mean: " + near.join(", ") : "Methods: " + names.join(", ")}`);
    }
    return text(JSON.stringify({
      tool: TOOL,
      method: m.method,
      legacy_name: m.def.name,
      description: m.def.description,
      params_schema: jsonSchemaOf(m.def),
    }, null, 2));
  });
  return all;
}

/** MCP_LEGACY_TOOLS=1: also expose the old per-tool names, handlers untouched. */
export function registerLegacy(server: McpServer, reg: ToolRegistry): void {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const s: any = server;
  for (const d of reg.defs.values()) {
    if (d.shape) s.tool(d.name, d.description, d.shape, d.handler);
    else s.tool(d.name, d.description, d.handler);
  }
}
