/**
 * The six tools.
 *
 * Deliberately NOT one tool per app, and not tools generated from each app's
 * /api/docs. An MCP tool is {name, schema, call} — it needs no process of its
 * own, so twenty apps do not need twenty servers. And generating the tool list
 * from the devices at connect time would mean a phone that is asleep or off
 * the mesh yields a server with zero tools, which is exactly when you reach
 * for it. A fixed set that takes `app` as an argument survives both.
 *
 * superapp_call is the escape hatch that keeps this file from ever needing to
 * know about a new app: AppDebugServer.route("news") { ... } in cloud-news
 * becomes callable the moment the APK lands, with no change here. superapp_docs
 * is how it stays discoverable.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { App, PORT_DEVCONTROL, get, scan } from "./device.js";

/** /api/<group>/<op>. No dots, no %, no scheme — a route name, not a URL. The
 *  value comes from the model, and device.ts escapes it into a shell script. */
export const ROUTE_RE = /^\/?[A-Za-z0-9_-]+(\/[A-Za-z0-9_-]+)*\/?$/;

let cache: App[] | null = null;

async function apps(refresh = false): Promise<App[]> {
  if (refresh || !cache) cache = await scan();
  return cache;
}

export function label(a: App): string {
  return a.pkg || (a.port === PORT_DEVCONTROL ? "devcontrol" : "unknown");
}

/**
 * Accepts a port, a full applicationId, or any unambiguous substring of one.
 * Substrings matter because the useful name is the tail: "mail" reads better
 * than "com.diegonmarcos.comms.mail". A pkg can hold more than one port — the
 * engines run in their own processes and each gets a server — so an exact pkg
 * match takes the lowest port rather than refusing.
 */
export function resolve(list: App[], query: string): App {
  if (list.length === 0) {
    throw new Error(
      "no app is serving the debug API — the phone is reachable but nothing answered " +
        "/api/system/ping. Is a constellation app running?",
    );
  }
  const q = query.trim();

  if (/^\d+$/.test(q)) {
    const byPort = list.find((a) => a.port === Number(q));
    if (byPort) return byPort;
    throw new Error(`nothing on port ${q}. Live: ${list.map((a) => `${label(a)}@${a.port}`).join(", ")}`);
  }

  const exact = list.filter((a) => a.pkg === q || label(a) === q);
  if (exact.length) return exact.sort((a, b) => a.port - b.port)[0];

  const partial = list.filter((a) => label(a).toLowerCase().includes(q.toLowerCase()));
  if (partial.length === 1) return partial[0];
  if (partial.length > 1) {
    const sameP = partial.every((a) => a.pkg === partial[0].pkg);
    if (sameP) return partial.sort((a, b) => a.port - b.port)[0];
    throw new Error(`"${q}" matches ${partial.map((a) => `${label(a)}@${a.port}`).join(", ")} — be specific`);
  }
  throw new Error(`no app matches "${q}". Live: ${list.map((a) => `${label(a)}@${a.port}`).join(", ")}`);
}

const text = (s: string) => ({ content: [{ type: "text" as const, text: s || "(empty response)" }] });

export function registerTools(server: McpServer): void {
  server.tool(
    "superapp_apps",
    "List every constellation app currently serving the on-device debug API on the phone: applicationId, bound port, label, version and device. Start here — the other tools take one of these as `app`.",
    {
      refresh: z.boolean().optional().describe("Re-scan the port range instead of using the cached sweep"),
    },
    async ({ refresh }) => {
      const list = await apps(refresh ?? false);
      if (!list.length) return text("no app is serving the debug API right now");
      const rows = await Promise.all(
        list.map(async (a) => {
          const info = await get(a.port, "system/info", {}, 8).catch(() => "");
          return { port: a.port, name: label(a), info: info.trim() || "(needs SUPERAPP_FLEET_TOKEN)" };
        }),
      );
      return text(rows.map((r) => `${r.name} @ ${r.port}\n  ${r.info}`).join("\n\n"));
    },
  );

  server.tool(
    "superapp_logcat",
    "Read one app's OWN logcat. Android filters logcat by uid, so this is the only way to see a constellation app's logs — no other process, ssh session included, can read them.",
    {
      app: z.string().describe("applicationId, a substring of it, or a port from superapp_apps"),
      lines: z.number().int().min(1).max(20000).optional().describe("Lines to return (default 300, max 20000)"),
    },
    async ({ app, lines }) => {
      const a = resolve(await apps(), app);
      const q: Record<string, string> = lines ? { n: String(lines) } : {};
      return text(await get(a.port, "diagnostics/logcat", q, 30));
    },
  );

  server.tool(
    "superapp_crashes",
    "Stored crash reports for one app, newest first, as written by AppCrashLogger.",
    { app: z.string().describe("applicationId, a substring of it, or a port") },
    async ({ app }) => text(await get((resolve(await apps(), app)).port, "diagnostics/crashes")),
  );

  server.tool(
    "superapp_docs",
    "One app's route catalog: the universal endpoints plus any group the app registered with AppDebugServer.route(). Read this before superapp_call to learn what that app actually serves.",
    { app: z.string().describe("applicationId, a substring of it, or a port") },
    async ({ app }) => text(await get((resolve(await apps(), app)).port, "docs")),
  );

  server.tool(
    "superapp_wake",
    "Start another constellation member's process through its content provider. No activity is launched, so Android's background-start restrictions do not apply — use it to bring an app up before reading its logs.",
    {
      app: z.string().describe("The app to ask (any live member will do)"),
      target: z.string().describe("applicationId of the member to wake, e.g. com.diegonmarcos.comms.mail"),
    },
    async ({ app, target }) => {
      if (!/^[A-Za-z0-9_.]+$/.test(target)) throw new Error(`not an applicationId: ${target}`);
      return text(await get((resolve(await apps(), app)).port, "fleet/wake", { pkg: target }));
    },
  );

  server.tool(
    "superapp_call",
    "Call any route on one app's debug API, including app-specific groups registered via AppDebugServer.route(). This is what makes a new app route usable with no change to this MCP — list them with superapp_docs first.",
    {
      app: z.string().describe("applicationId, a substring of it, or a port"),
      path: z.string().describe("Route under /api/, e.g. 'news/latest' or 'fleet/peers'"),
      params: z.record(z.string(), z.string()).optional().describe("Query parameters"),
    },
    async ({ app, path, params }) => {
      if (!ROUTE_RE.test(path)) {
        throw new Error(`bad route "${path}" — expected /api/<group>/<op>, letters, digits, _ and - only`);
      }
      return text(await get((resolve(await apps(), app)).port, path, params ?? {}, 30));
    },
  );
}
