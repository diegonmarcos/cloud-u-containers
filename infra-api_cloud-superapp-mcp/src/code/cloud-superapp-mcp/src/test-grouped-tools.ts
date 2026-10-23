/**
 * Grouped-dispatcher self-check: `npx tsx test-grouped-tools.ts`
 * Drives the real server through an in-memory MCP client. No phone needed.
 */
import assert from "node:assert/strict";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { z } from "zod";
import { buildRegistry, registerAll } from "../../lib-mcp/src/tools.js";
import { ToolRegistry, methodsOf, registerGrouped, registerLegacy } from "../../lib-mcp/src/grouped.js";

const MAX_LIST_BYTES = 3 * 1024; // guard: total tools/list JSON must stay under this
const EXPECTED = ["apps", "call", "docs", "crashes", "logcat", "logcat_full", "shell", "input", "screencap", "grant", "force_stop", "wake", "adb_status", "adb_pair", "adb_autoconnect"];

async function connect(server: McpServer) {
  const [a, b] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: "t", version: "1" });
  await Promise.all([server.connect(a), client.connect(b)]);
  return client;
}
const mk = (env: NodeJS.ProcessEnv = {}) => { const s = new McpServer({ name: "s", version: "1" }); registerAll(s, [], env); return s; };
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const txt = (r: any) => r.content.map((c: any) => c.text).join("");
let n = 0;
const t = async (name: string, fn: () => Promise<void> | void) => { await fn(); n++; console.log(`  ok ${name}`); };

const reg = buildRegistry();
const all = methodsOf(reg);
const client = await connect(mk());

await t("default exposes only superapp + superapp_help", async () => {
  const names = (await client.listTools()).tools.map((x) => x.name).sort();
  assert.deepEqual(names, ["superapp", "superapp_help"]);
});

await t("registry holds the 15 methods", () => {
  assert.deepEqual(all.map((m) => m.method).sort(), [...EXPECTED].sort());
});

await t("every method is in the enum and superapp_help returns its schema", async () => {
  const tool = (await client.listTools()).tools.find((x) => x.name === "superapp")!;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const en = (tool.inputSchema as any).properties.method.enum as string[];
  for (const m of all) {
    assert.ok(en.includes(m.method), `${m.method} missing from enum`);
    assert.ok(tool.description!.includes(`${m.method}: `), `${m.method} missing from description`);
    const h = await client.callTool({ name: "superapp_help", arguments: { method: m.method } });
    assert.ok(!h.isError, `${m.method}: ${txt(h)}`);
    const j = JSON.parse(txt(h));
    assert.equal(j.legacy_name, m.def.name);
    assert.equal(j.description, m.def.description);
    assert.equal(j.params_schema.type, "object");
    assert.deepEqual(Object.keys(j.params_schema.properties ?? {}).sort(), Object.keys(m.def.shape ?? {}).sort());
  }
});

await t("dispatch routes 1:1 to the handler (stub registry)", async () => {
  const r = new ToolRegistry();
  const calls: unknown[] = [];
  r.tool("superapp_echo", "Echo back", { msg: z.string(), loud: z.boolean().optional() }, async (a: unknown) => { calls.push(a); return { content: [{ type: "text", text: "ok" }] }; });
  r.tool("superapp_ping", "Ping", {}, async () => ({ content: [{ type: "text", text: "pong" }] }));
  const s = new McpServer({ name: "s", version: "1" });
  registerGrouped(s, r);
  const c = await connect(s);
  assert.equal(txt(await c.callTool({ name: "superapp", arguments: { method: "echo", params: { msg: "x" } } })), "ok");
  assert.deepEqual(calls, [{ msg: "x" }]);
  assert.equal(txt(await c.callTool({ name: "superapp", arguments: { method: "ping" } })), "pong");
});

await t("param validation points to superapp_help; unknown method rejected", async () => {
  const call = (method: string, params?: unknown) => client.callTool({ name: "superapp", arguments: { method, params } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let x: any = await call("crashes", {});
  assert.ok(x.isError && /app: Required/.test(txt(x)) && /superapp_help/.test(txt(x)), txt(x));
  x = await call("crashes", { app: 5 });
  assert.ok(x.isError && /app: Expected string/.test(txt(x)), txt(x));
  x = await call("crashes", { app: "a", bogus: 1 });
  assert.ok(x.isError && /bogus/.test(txt(x)), txt(x));
  x = await call("grant", { app: "a", permission: "bad perm!" });
  assert.ok(x.isError && /permission/.test(txt(x)), txt(x));
  x = await call("nope", {});
  assert.ok(x.isError || /Invalid enum/.test(JSON.stringify(x)), JSON.stringify(x));
  x = await client.callTool({ name: "superapp_help", arguments: { method: "nope" } });
  assert.ok(x.isError && /Unknown method/.test(txt(x)));
});

await t("handler guards still fire through the dispatcher (shell allowlist)", async () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const x: any = await client.callTool({ name: "superapp", arguments: { method: "shell", params: { cmd: "rm -rf /" } } });
  assert.ok(x.isError && /allowlist/.test(txt(x)), txt(x));
});

await t("MCP_LEGACY_TOOLS=1 exposes every old name plus the dispatcher; default OFF", async () => {
  const c = await connect(mk({ MCP_LEGACY_TOOLS: "1" }));
  const names = new Set((await c.listTools()).tools.map((x) => x.name));
  for (const d of reg.defs.values()) assert.ok(names.has(d.name), `legacy ${d.name} missing`);
  assert.ok(names.has("superapp") && names.has("superapp_help"));
});

await t("SIZE GUARD: tools/list JSON under cap (report before/after)", async () => {
  const after = JSON.stringify(await client.listTools()).length;
  const lg = new McpServer({ name: "old", version: "1" });
  registerLegacy(lg, reg);
  const before = JSON.stringify(await (await connect(lg)).listTools()).length;
  console.log(`tools/list bytes: before=${before} (${reg.defs.size} tools) after=${after} (2 tools)`);
  assert.ok(after <= MAX_LIST_BYTES, `tools/list is ${after} bytes, cap ${MAX_LIST_BYTES}`);
});

console.log(`${n} grouped-tools tests passed`);
process.exit(0);
