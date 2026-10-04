#!/usr/bin/env node
/**
 * The HTTP face of the same thing the MCP serves.
 *
 * Same modules, same transport, no second source of truth: a curl-able
 * surface for the things that are not a model — a dashboard, a shell script,
 * the watchdog. It is NOT a second proxy. If a behaviour differs between this
 * and the MCP, that is a bug in one of them, not a feature of either.
 *
 * Binds loopback only. The phone's own API is loopback-on-the-phone and
 * reached over ssh; this one has no authentication of its own, so it must not
 * be the thing that puts those routes on a network.
 */
import { createServer } from "node:http";
import { get, scan } from "../../lib-mcp/src/device.js";
import { loadModules, type AppModule } from "../../lib-mcp/src/registry.js";
import { CONTRACT, path as routePath } from "../../lib-api/src/contract.js";

const PORT = Number(process.env.SUPERAPP_API_PORT ?? 38150);
const ROUTE_RE = /^[A-Za-z0-9_-]+(\/[A-Za-z0-9_-]+)*$/;

let modules: AppModule[] = [];

function pkgOf(q: string): string {
  const m = modules.find((x) => x.id.toLowerCase() === q.toLowerCase());
  return m?.pkg || q;
}

async function portOf(q: string): Promise<number> {
  const wanted = pkgOf(q);
  const live = await scan();
  const hit =
    live.find((a) => a.pkg === wanted) ??
    live.find((a) => a.pkg.toLowerCase().includes(wanted.toLowerCase()));
  if (!hit) throw new Error(`no live app matches "${q}" — live: ${live.map((a) => a.pkg || a.port).join(", ")}`);
  return hit.port;
}

const server = createServer(async (req, res) => {
  const send = (code: number, body: string, type = "text/plain; charset=utf-8") => {
    res.writeHead(code, { "content-type": type });
    res.end(body);
  };
  try {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const seg = url.pathname.split("/").filter(Boolean);

    // GET /apps                    → what the phone is serving right now
    if (seg[0] === "apps" && seg.length === 1) {
      return send(200, JSON.stringify(await scan(), null, 2), "application/json");
    }
    // GET /contract                → what every app is guaranteed to answer
    if (seg[0] === "contract") {
      return send(200, JSON.stringify(CONTRACT.map((r) => ({ path: routePath(r), ...r })), null, 2), "application/json");
    }
    // GET /modules                 → the mcps-apps roster, phone or no phone
    if (seg[0] === "modules") {
      return send(200, JSON.stringify(modules, null, 2), "application/json");
    }
    // GET /call/<app>/<group>/<op> → one route on one app
    if (seg[0] === "call" && seg.length >= 3) {
      const [, app, ...rest] = seg;
      const route = rest.join("/");
      if (!ROUTE_RE.test(route)) return send(400, `bad route "${route}"`);
      const q = Object.fromEntries(url.searchParams);
      return send(200, await get(await portOf(app), route, q, 30));
    }
    send(404, "GET /apps | /contract | /modules | /call/<app>/<group>/<op>");
  } catch (e) {
    send(502, `${(e as Error).message}\n`);
  }
});

async function main() {
  modules = await loadModules();
  // Loopback only — see the header. Never 0.0.0.0.
  server.listen(PORT, "127.0.0.1", () =>
    process.stderr.write(`[cloud-superapp-api] 127.0.0.1:${PORT}, ${modules.length} modules\n`),
  );
}

main().catch((e) => {
  process.stderr.write(`[cloud-superapp-api] fatal: ${e}\n`);
  process.exit(1);
});
