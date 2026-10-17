/**
 * Transport to the phone's on-device debug API.
 *
 * #ipc (cloud-u-android a0_docs/eng-specs/fleet-ipc.md) ONE DOOR PER PHONE: the
 * SuperApp's DevControlServer on 127.0.0.1:38080 is the only fleet app that
 * listens. It lists what is behind it at /api/fleet/apps and forwards
 * /app/<pkg>/api/<op> to that app over Android IPC (signature-checked, waking
 * the app), with the one fleet token. Older phones still run builds where
 * every app bound its own loopback port in 38090..38389: when the gateway does
 * not answer /api/fleet/apps, scan() sweeps those ports as before, and each
 * App says which way it is reached (`gateway`).
 *
 * Those sockets bind 127.0.0.1, so nothing off-device can reach them — a
 * container on oci-apps never could. We go in the way a human already does:
 * `ssh phone` (our Cloud Terminal (nix) sshd, mesh 10.0.0.9:8024; phone-termux = the
 * termux build on :8023) and curl from inside. Aliases come from build.json
 * ssh.extra_hosts; mesh only, there is no public route to the phone.
 *
 * The primitive is "run this shell script over there", not "fetch this URL",
 * because the port scan is 60 probes. One remote loop is one round trip;
 * 60 ssh invocations is a minute of handshakes.
 */
import { spawn } from "node:child_process";

/** Try in order, remember the first that answers. `local` = run here (the
 *  termux/on-device Claude, where 127.0.0.1 already IS the phone). */
const HOSTS = (process.env.SUPERAPP_HOSTS ?? "phone,phone-v6,phone-termux,phone-termux-v6")
  .split(",")
  .map((h) => h.trim())
  .filter(Boolean);

const SSH_TIMEOUT_MS = Number(process.env.SUPERAPP_SSH_TIMEOUT_MS ?? 30_000);

/** Set from SuperApp → Configs → About. Absent is not fatal: /api/system/ping
 *  is open, so discovery still works and only the data routes answer 401. */
/**
 * An unexpanded ${VAR} counts as absent.
 *
 * ~/.mcp.json is rendered from a template whose placeholders the mcpSecrets
 * activation fills from sops. A key that is missing there is left VERBATIM —
 * so this arrives as the literal string "${SUPERAPP_FLEET_TOKEN}",
 * which is truthy, passes any `unset` check, and gets sent as a Bearer token
 * the phone rejects. Every data route then answers 401 with nothing anywhere
 * saying why. Treat it as the miss it is.
 */
export function fleetToken(): string {
  const raw = process.env.SUPERAPP_FLEET_TOKEN ?? "";
  return /^\$\{[A-Za-z_][A-Za-z0-9_-]*\}$/.test(raw.trim()) ? "" : raw;
}

const TOKEN = fleetToken();

export const PORT_DEVCONTROL = 38080;
/** The pre-gateway per-app range (cloud-u-android 1_cicd/src/data/debug-ports.json), swept only
 *  when the gateway does not answer: a phone whose SuperApp predates it. */
export const PORT_FIRST = 38090;
export const PORT_LAST = 38389;

let goodHost: string | null = null;

/** Single-quote for /bin/sh. Everything that reaches the remote shell goes
 *  through here — app names, paths and the fleet token all arrive from the
 *  model, and the script is the trust boundary. */
export function sq(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function exec(cmd: string, args: string[], stdin: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      p.kill("SIGKILL");
      reject(new Error(`${cmd} timed out after ${SSH_TIMEOUT_MS}ms`));
    }, SSH_TIMEOUT_MS);
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    p.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(out);
      else reject(new Error(`${cmd} exited ${code}: ${err.trim() || out.trim()}`));
    });
    p.stdin.end(stdin);
  });
}

/**
 * Run a POSIX sh script on the phone and return its stdout.
 *
 * The script rides stdin rather than argv so the fleet token never appears in
 * the phone's process table.
 */
export async function run(script: string): Promise<string> {
  if (HOSTS.length === 1 && HOSTS[0] === "local") {
    return exec("sh", ["-s"], script);
  }
  const order = goodHost ? [goodHost, ...HOSTS.filter((h) => h !== goodHost)] : HOSTS;
  const errors: string[] = [];
  for (const host of order) {
    try {
      const out = await exec(
        "ssh",
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "sh", "-s"],
        script,
      );
      goodHost = host;
      return out;
    } catch (e) {
      errors.push(`${host}: ${(e as Error).message}`);
      if (goodHost === host) goodHost = null;
    }
  }
  throw new Error(`no route to the phone — ${errors.join(" | ")}`);
}

export type App = {
  /** applicationId, or "" for the old DevControlServer, whose ping predates
   *  the package suffix. */
  pkg: string;
  port: number;
  /** #ipc reached through the SuperApp gateway (port = PORT_DEVCONTROL), not its own port. */
  gateway?: boolean;
};

/** The gateway's member list: one App per fleet member behind the door. Null when the
 *  gateway does not answer (no SuperApp, or one from before the gateway). */
export function parseGatewayApps(body: string): App[] | null {
  try {
    const o = JSON.parse(body);
    if (!o || !Array.isArray(o.apps)) return null;
    return o.apps
      .filter((a: { pkg?: unknown }) => typeof a.pkg === "string" && a.pkg)
      .map((a: { pkg: string }) => ({ pkg: a.pkg, port: PORT_DEVCONTROL, gateway: true }));
  } catch {
    return null;
  }
}

/** /app/<pkg>/api/<path> on the gateway, or /api/<path> on the app's own legacy port. */
export function urlOf(a: App, path: string, qs = ""): string {
  const p = path.replace(/^\/+/, "");
  const base = a.gateway ? `http://127.0.0.1:${PORT_DEVCONTROL}/app/${a.pkg}/api/${p}` : `http://127.0.0.1:${a.port}/api/${p}`;
  return base + (qs ? `?${qs}` : "");
}

/**
 * One sweep of the port range. /api/system/ping is deliberately the OPEN
 * route in AppDebugServer precisely so this works before any token exists —
 * it answers `pong <applicationId>`.
 */
export async function scan(): Promise<App[]> {
  const viaGateway = parseGatewayApps(await get(PORT_DEVCONTROL, "fleet/apps", {}, 8).catch(() => ""));
  if (viaGateway && viaGateway.length) return viaGateway;
  const script = `
for p in ${PORT_DEVCONTROL} $(seq ${PORT_FIRST} ${PORT_LAST}); do
  r=$(curl -s -m 1 "http://127.0.0.1:$p/api/system/ping" 2>/dev/null) || continue
  [ -n "$r" ] && echo "$p $r"
done
exit 0
`;
  const out = await run(script);
  const apps: App[] = [];
  for (const line of out.split("\n")) {
    const m = line.match(/^(\d+)\s+pong\s*(\S*)/);
    if (m) apps.push({ port: Number(m[1]), pkg: m[2] ?? "" });
  }
  return apps;
}

/** GET /api/<path> on one port (the gateway's own routes, or a pre-gateway app's). */
export async function get(
  port: number,
  path: string,
  query: Record<string, string> = {},
  timeoutSec = 20,
): Promise<string> {
  return fetchUrl(urlOf({ pkg: "", port }, path, qs(query)), timeoutSec);
}

/** #ipc one app's route, through the gateway when that is how it was found. */
export async function call(
  a: App,
  path: string,
  query: Record<string, string> = {},
  timeoutSec = 20,
): Promise<string> {
  return fetchUrl(urlOf(a, path, qs(query)), timeoutSec);
}

function qs(query: Record<string, string>): string {
  return Object.entries(query)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
}

/**
 * curl one loopback URL on the phone. `path` and every query value are escaped
 * into the script; the caller has already validated `path` against the
 * route-shape allowlist in tools.ts.
 */
async function fetchUrl(url: string, timeoutSec: number): Promise<string> {
  const auth = TOKEN ? `-H "Authorization: Bearer $T" ` : "";
  const script = `
T=${sq(TOKEN)}
curl -s -m ${timeoutSec} ${auth}${sq(url)}
exit 0
`;
  return run(script);
}
