// ── Cloudflare bridge: API (incl. Zero Trust / Access / Tunnel / Gateway),
//    cloudflared and wrangler — read-only by default, writes gated + audited.
//
// Read tools (no side effects):
//   obs.debug.cf_api          — GET presets (tunnels, routes, access_apps, …) + raw GET path
//   obs.debug.cf_cloudflared  — cloudflared read-only subcommands
// Write tools (dry-run unless confirm=true; every executed write is audited):
//   devops.cf.api_write        — POST/PUT/PATCH/DELETE any allowed API path
//   devops.cf.tunnel_route_dns — CNAME <hostname> → <tunnel>.cfargotunnel.com
//   devops.cf.tunnel_route_ip  — private network route CIDR → tunnel
//   devops.cf.cloudflared_write — cloudflared tunnel create/delete/route/vnet …
//   devops.cf.wrangler_write   — wrangler deploy/delete/kv put/…
//
// Credentials come from sops (.secrets → env): CF_API_TOKEN, or CF_API_KEY +
// CF_API_EMAIL (global key). They go in request headers built by fetch — never
// on any argv — and every response passes through redactCfJson/redactCfString.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/libs/exec.js";
import { audit } from "../../shared/libs/audit.js";
import { redactCommandString } from "../../shared/libs/redact-argv.js";
import {
  CF_READ_PRESETS, cfAuthFromEnv, cfSecretValues, validateApiPath, gateWrite, fillPresetPath,
  tokenizeArgs, classifyCloudflared, classifyWrangler, redactCfJson, redactCfString, project,
  explainCfError, writeScopeFor,
} from "./cf-policy.js";

const API = "https://api.cloudflare.com/client/v4";
const MAX_OUT = 60_000;

type Txt = { content: { type: "text"; text: string }[] };
function safeRun(fn: () => Promise<string>): Promise<Txt> {
  return fn()
    .then((text) => ({ content: [{ type: "text" as const, text: clip(scrub(text)) }] }))
    .catch((err) => ({ content: [{ type: "text" as const, text: `ERROR: ${scrub(err instanceof Error ? err.message : String(err))}` }] }));
}
const clip = (s: string) => (s.length > MAX_OUT ? `${s.slice(0, MAX_OUT)}\n… (truncated at ${MAX_OUT} chars — narrow with id/path or full=false)` : s);
/** Last line of defence on everything this module returns. */
export function scrub(s: string): string {
  return redactCommandString(redactCfString(s, cfSecretValues(process.env)));
}

// ── API client ───────────────────────────────────────────────────────────────

interface CfResp { status: number; json: any; text: string }

export async function cfFetch(method: string, path: string, body?: unknown): Promise<CfResp> {
  const auth = cfAuthFromEnv(process.env);
  if (auth.mode === "none") throw new Error("No Cloudflare credential in env (CF_API_TOKEN, or CF_API_KEY + CF_API_EMAIL from src/secrets.yaml).");
  const headers: Record<string, string> = { ...auth.headers, Accept: "application/json" };
  let payload: string | undefined;
  if (body !== undefined && body !== null && body !== "") {
    payload = typeof body === "string" ? body : JSON.stringify(body);
    headers["Content-Type"] = "application/json";
  }
  const r = await fetch(`${API}${path}`, { method, headers, body: payload, signal: AbortSignal.timeout(25_000) });
  const text = await r.text();
  let json: any = null;
  try { json = JSON.parse(text); } catch { /* non-JSON */ }
  return { status: r.status, json, text };
}

/** GET with pagination (up to 10 pages) for list endpoints. */
async function cfGetAll(path: string): Promise<CfResp> {
  const first = await cfFetch("GET", path);
  const info = first.json?.result_info;
  if (!first.json?.success || !Array.isArray(first.json?.result) || !info?.total_pages || info.total_pages <= 1) return first;
  const all = [...first.json.result];
  const sep = path.includes("?") ? "&" : "?";
  for (let p = 2; p <= Math.min(info.total_pages, 10); p++) {
    const r = await cfFetch("GET", `${path}${sep}page=${p}`);
    if (!r.json?.success || !Array.isArray(r.json.result)) break;
    all.push(...r.json.result);
  }
  first.json.result = all;
  return first;
}

let accountCache: string | null = null;
async function accountId(): Promise<string> {
  if (process.env.CF_ACCOUNT_ID) return process.env.CF_ACCOUNT_ID;
  if (accountCache) return accountCache;
  const r = await cfFetch("GET", "/accounts?per_page=5");
  const acc = r.json?.result?.[0]?.id;
  if (!acc) throw new Error(`Could not resolve the account id: ${explainCfError(r.status, r.json?.errors, "Account · Account Settings · Read")}`);
  accountCache = acc;
  return acc;
}

async function zoneId(nameOrId?: string): Promise<string> {
  if (nameOrId && /^[0-9a-f]{32}$/.test(nameOrId)) return nameOrId;
  if (!nameOrId && process.env.CF_ZONE_ID) return process.env.CF_ZONE_ID;
  const q = nameOrId ? `/zones?name=${encodeURIComponent(nameOrId)}` : "/zones?per_page=1";
  const r = await cfFetch("GET", q);
  const z = r.json?.result?.[0]?.id;
  if (!z) throw new Error(`Zone ${nameOrId ?? "(default)"} not found: ${explainCfError(r.status, r.json?.errors, "Zone · Zone · Read")}`);
  return z;
}

/** Longest-suffix zone match for a hostname (a.b.example.com → example.com). */
async function zoneForHostname(host: string): Promise<{ id: string; name: string }> {
  const parts = host.toLowerCase().split(".");
  for (let i = 0; i < parts.length - 1; i++) {
    const cand = parts.slice(i).join(".");
    const r = await cfFetch("GET", `/zones?name=${encodeURIComponent(cand)}`);
    const z = r.json?.result?.[0];
    if (z?.id) return { id: z.id, name: z.name };
  }
  throw new Error(`No zone on this account covers ${host}`);
}

function render(title: string, r: CfResp, scope: string, fields?: string[], full?: boolean): string {
  const secrets = cfSecretValues(process.env);
  const head = `CLOUDFLARE API → ${title}\n${"─".repeat(60)}`;
  if (!r.json) return `${head}\nHTTP ${r.status} (non-JSON)\n${redactCfString(r.text.slice(0, 2000), secrets)}`;
  if (!r.json.success) return `${head}\n${explainCfError(r.status, r.json.errors, scope)}`;
  const res = redactCfJson(r.json.result, secrets);
  const shown = full ? res : project(res, fields);
  const count = Array.isArray(res) ? `${res.length} item(s)\n` : "";
  return `${head}\n${count}${JSON.stringify(shown, null, 2)}`;
}

// ── Read path ────────────────────────────────────────────────────────────────

async function cfReadRaw(opts: { preset?: string; id?: string; zone?: string; path?: string; full?: boolean }): Promise<string> {
  const { preset, id, zone, path, full } = opts;
  if (path) {
    const chk = validateApiPath(path.replace("${account}", "__ACC__"), "GET");
    if (!chk.ok) return `REFUSED: ${chk.reason}`;
    let p = chk.path;
    if (p.includes("__ACC__")) p = p.replace("__ACC__", await accountId());
    return render(`GET ${p}`, await cfGetAll(p), writeScopeFor(p).replace("Edit", "Read"), undefined, true);
  }
  if (!preset || preset === "help") {
    const rows = Object.entries(CF_READ_PRESETS).map(([k, v]) => `  ${k.padEnd(20)} ${v.needsId ? "(id) " : ""}${v.desc}\n  ${"".padEnd(20)} scope: ${v.scope}`);
    return `obs.debug.cf_api — read-only presets (GET)\n${"═".repeat(60)}\n${rows.join("\n")}\n  ${"scopes".padEnd(20)} probe every list preset and report which permissions are missing\n\nOr path="/accounts/\${account}/..." for any other GET (secret-returning endpoints are refused).\nWrites: devops.cf.api_write / tunnel_route_dns / tunnel_route_ip (confirm=true).`;
  }
  if (preset === "scopes") return scopeReport();
  const def = CF_READ_PRESETS[preset];
  if (!def) return `Unknown preset "${preset}". Presets: ${Object.keys(CF_READ_PRESETS).join(", ")}, scopes`;
  const auth = cfAuthFromEnv(process.env);
  if (preset === "auth") {
    const p = auth.mode === "token" ? "/user/tokens/verify" : "/user";
    return `auth mode: ${auth.mode === "global" ? "global API key (X-Auth-Email/X-Auth-Key) — every permission the user has" : auth.mode}\n` +
      render(`GET ${p}`, await cfFetch("GET", p), def.scope, auth.mode === "token" ? ["id", "status", "expires_on"] : def.fields, full);
  }
  const vars: { account?: string; zone?: string; id?: string } = { id };
  if (def.path.includes("${account}")) vars.account = await accountId();
  if (def.path.includes("${zone}")) vars.zone = await zoneId(zone ?? (preset === "dns" || preset === "firewall" ? id : undefined));
  if (def.path.includes("${id}") && !id) return `Preset "${preset}" needs id.`;
  const filled = fillPresetPath(def.path, vars);
  if (!filled.ok) return `REFUSED: ${filled.reason}`;
  const chk = validateApiPath(filled.path, "GET");
  if (!chk.ok) return `REFUSED: ${chk.reason}`;
  return render(`${preset} (GET ${chk.path})`, await cfGetAll(chk.path), def.scope, def.fields, full);
}

async function scopeReport(): Promise<string> {
  const acc = await accountId();
  const auth = cfAuthFromEnv(process.env);
  const lines: string[] = [`Credential mode: ${auth.mode}`, "─".repeat(60)];
  const missing = new Set<string>();
  for (const [name, def] of Object.entries(CF_READ_PRESETS)) {
    if (def.needsId || name === "auth") continue;
    let path = def.path.replace("${account}", acc);
    if (path.includes("${zone}")) { try { path = path.replace("${zone}", await zoneId()); } catch { lines.push(`  ?    ${name.padEnd(20)} no zone`); continue; } }
    const r = await cfFetch("GET", path);
    const ok = r.json?.success === true;
    const notEnabled = (r.json?.errors ?? []).some((e: any) => /not.?enabled/i.test(e?.message ?? ""));
    if (!ok && !notEnabled && (r.status === 403 || r.status === 401)) missing.add(def.scope);
    lines.push(`  ${ok ? "OK  " : notEnabled ? "OFF " : "FAIL"} ${name.padEnd(20)} ${ok ? "" : notEnabled ? "feature not enabled on the account (dashboard onboarding, not a scope)" : `HTTP ${r.status} → needs ${def.scope}`}`);
  }
  lines.push("─".repeat(60));
  lines.push(missing.size ? `Missing read permissions:\n  - ${[...missing].join("\n  - ")}` : "No missing read permissions.");
  if (auth.mode === "token") lines.push("Writes additionally need the matching · Edit permissions (Cloudflare Tunnel, Access: Apps and Policies, Access: Service Tokens, Access: Organizations…, Zero Trust, DNS).");
  return lines.join("\n");
}

/** Exported read entry points always return scrubbed text (also used by vps-ops.ts). */
export async function cfRead(opts: { preset?: string; id?: string; zone?: string; path?: string; full?: boolean }): Promise<string> {
  return scrub(await cfReadRaw(opts));
}

// ── Write path ───────────────────────────────────────────────────────────────

async function cfWrite(tool: string, method: string, rawPath: string, body: unknown, confirm: boolean | undefined): Promise<string> {
  const m = (method || "").toUpperCase();
  const chk0 = validateApiPath(rawPath.replace("${account}", "__ACC__"), m);
  if (!chk0.ok) { audit(tool, `${m} ${rawPath}`, `REFUSED ${chk0.reason}`); return `REFUSED: ${chk0.reason}`; }
  if (!["POST", "PUT", "PATCH", "DELETE"].includes(m)) return `REFUSED: ${tool} is for writes; use obs.debug.cf_api for GET.`;
  let path = chk0.path;
  if (path.includes("__ACC__")) path = path.replace("__ACC__", await accountId());
  let parsed: unknown = undefined;
  if (typeof body === "string" && body.trim() !== "") {
    try { parsed = JSON.parse(body); } catch { return "REFUSED: body is not valid JSON."; }
  } else if (body && typeof body === "object") parsed = body;
  const gate = gateWrite(m, confirm);
  const preview = `${m} ${path}${parsed !== undefined ? `\nbody: ${JSON.stringify(redactCfJson(parsed, cfSecretValues(process.env)), null, 2)}` : ""}`;
  if (!gate.run) return `DRY-RUN (nothing sent)\n${preview}\n\n${gate.reason}\nNeeds (scoped token): ${writeScopeFor(path)}`;
  const r = await cfFetch(m, path, parsed);
  const ok = r.json?.success === true;
  audit(tool, `${m} ${path}`, ok ? `OK HTTP ${r.status}` : `FAILED HTTP ${r.status} ${(r.json?.errors ?? []).map((e: any) => e.code).join(",")}`);
  return render(`${m} ${path} (audited)`, r, writeScopeFor(path), undefined, true);
}

// ── CLI path (cloudflared / wrangler) ────────────────────────────────────────

let cliEnvReady = false;
async function prepareCliEnv(): Promise<void> {
  if (cliEnvReady) return;
  const auth = cfAuthFromEnv(process.env);
  if (auth.mode === "global") {
    process.env.CLOUDFLARE_API_KEY ??= process.env.CF_API_KEY;
    process.env.CLOUDFLARE_EMAIL ??= process.env.CF_API_EMAIL;
  } else if (auth.mode === "token") {
    process.env.CLOUDFLARE_API_TOKEN ??= process.env.CF_API_TOKEN ?? process.env.CF_API_KEY;
  }
  try { process.env.CLOUDFLARE_ACCOUNT_ID ??= await accountId(); } catch { /* wrangler will ask */ }
  process.env.WRANGLER_SEND_METRICS = "false";
  process.env.NO_UPDATE_NOTIFIER = "1";
  process.env.NO_AUTOUPDATE = "true"; // cloudflared
  cliEnvReady = true;
}

async function runCfCli(bin: "cloudflared" | "wrangler", argv: string[], timeout = 60_000): Promise<string> {
  const which = await execAsync("bash", ["-c", `command -v ${bin}`], { timeout: 3_000 });
  if (!which.ok) return `${bin} not found in the image (installed by build.json docker.native_build — not shipped yet?).`;
  await prepareCliEnv();
  const r = await execAsync(bin, argv, { timeout });
  const out = `${r.stdout.trim()}${r.stderr.trim() ? `\n${r.stderr.trim()}` : ""}`.trim() || "(no output)";
  return r.ok ? out : `EXIT ${r.exitCode}${r.timedOut ? " (timed out)" : ""}\n${out}`;
}

async function cliReadRaw(bin: "cloudflared" | "wrangler", command: string): Promise<string> {
  const argv = tokenizeArgs(command);
  const cls = bin === "cloudflared" ? classifyCloudflared(argv) : classifyWrangler(argv);
  if (cls === "blocked") return `REFUSED: \`${bin} ${argv.join(" ")}\` prints/mints credentials, is interactive or long-running — not allowed through the MCP.`;
  if (cls === "write") return `REFUSED (read-only tool): \`${bin} ${argv.join(" ")}\` changes state. Use devops.cf.${bin}_write with confirm=true.`;
  return `${bin.toUpperCase()} → ${argv.join(" ")}\n${"─".repeat(50)}\n${await runCfCli(bin, argv)}`;
}

export async function cliRead(bin: "cloudflared" | "wrangler", command: string): Promise<string> {
  return scrub(await cliReadRaw(bin, command));
}

async function cliWrite(bin: "cloudflared" | "wrangler", command: string, confirm: boolean | undefined): Promise<string> {
  const argv = tokenizeArgs(command);
  const cls = bin === "cloudflared" ? classifyCloudflared(argv) : classifyWrangler(argv);
  const tool = `devops.cf.${bin}_write`;
  const shown = redactCommandString(argv.join(" "));
  if (cls === "blocked") { audit(tool, shown, "REFUSED blocked subcommand"); return `REFUSED: \`${bin} ${shown}\` is not allowed through the MCP.`; }
  if (cls === "read") return `\`${bin} ${shown}\` is read-only — use obs.debug.${bin === "cloudflared" ? "cf_cloudflared" : "vps_wrangler"}.`;
  if (confirm !== true) return `DRY-RUN (nothing executed): ${bin} ${shown}\nRepeat with confirm=true to run it (audited).`;
  const out = await runCfCli(bin, argv, 180_000);
  audit(tool, shown, out.startsWith("EXIT ") ? `FAILED ${out.split("\n")[0]}` : "OK");
  return `${bin.toUpperCase()} (audited) → ${shown}\n${"─".repeat(50)}\n${out}`;
}

// ── Registration ─────────────────────────────────────────────────────────────

export function registerCloudflareTools(server: McpServer): void {
  server.tool(
    "obs.debug.cf_api",
    "Cloudflare API, READ-ONLY (GET): tunnels (cfd_tunnel), private routes/vnets, Access apps/policies/service tokens/IdPs/groups, Gateway DNS locations/rules/lists, WARP device settings, zones/DNS, workers. Presets or a raw GET path. Credentials and secrets are redacted. preset='scopes' reports missing token permissions.",
    {
      preset: z.string().optional().describe(`Preset: ${Object.keys(CF_READ_PRESETS).join(", ")}, scopes. Omit for help.`),
      id: z.string().optional().describe("Object id for tunnel / tunnel_connections / tunnel_config / access_app / access_app_policies; zone name for dns"),
      zone: z.string().optional().describe("Zone name or id (dns, firewall). Default: first zone"),
      path: z.string().optional().describe("Raw GET path instead of a preset, e.g. /accounts/${account}/access/bookmarks"),
      full: z.boolean().optional().describe("Return the full (redacted) objects instead of the compact projection"),
    },
    (p) => safeRun(() => cfRead(p)),
  );

  server.tool(
    "obs.debug.cf_cloudflared",
    "cloudflared CLI, READ-ONLY subcommands (version, tunnel list|info|route ip show|vnet list|ingress validate, access ssh-config). `tunnel token`, login and access token are refused. Note: cloudflared's own tunnel management needs an origin cert (cert.pem) that the MCP does not hold — obs.debug.cf_api preset=tunnels/tunnel/routes is the credential-free equivalent.",
    { command: z.string().optional().describe("cloudflared arguments, e.g. 'version' or 'tunnel list'. Default: version") },
    ({ command }) => safeRun(() => cliRead("cloudflared", command?.trim() || "version")),
  );

  server.tool(
    "devops.cf.api_write",
    "Cloudflare API WRITE (POST/PUT/PATCH/DELETE) — Access apps/policies, Gateway rules/locations, tunnels, routes, DNS… DRY-RUN unless confirm=true; executed writes are audited (obs.debug.db_audit). Credential-minting endpoints (API tokens, tunnel token, service-token rotate) are refused.",
    {
      method: z.enum(["POST", "PUT", "PATCH", "DELETE"]),
      path: z.string().describe("API path, ${account} is filled in, e.g. /accounts/${account}/access/apps"),
      body: z.string().optional().describe("JSON body (string)"),
      confirm: z.boolean().optional().describe("true = actually send it. Omit for a dry-run preview"),
    },
    ({ method, path, body, confirm }) => safeRun(() => cfWrite("devops.cf.api_write", method, path, body, confirm)),
  );

  server.tool(
    "devops.cf.tunnel_route_dns",
    "Equivalent of `cloudflared tunnel route dns <tunnel> <hostname>`: create (or with overwrite=true update) a proxied CNAME <hostname> → <tunnel_id>.cfargotunnel.com. DRY-RUN unless confirm=true; audited.",
    {
      tunnel_id: z.string().regex(/^[0-9a-f-]{36}$/).describe("Tunnel UUID (obs.debug.cf_api preset=tunnels)"),
      hostname: z.string().regex(/^(?=.{1,253}$)([a-z0-9*]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i).describe("FQDN to route"),
      overwrite: z.boolean().optional().describe("Replace an existing record of the same name"),
      confirm: z.boolean().optional(),
    },
    ({ tunnel_id, hostname, overwrite, confirm }) => safeRun(async () => {
      const zn = await zoneForHostname(hostname);
      const target = `${tunnel_id}.cfargotunnel.com`;
      const ex = await cfFetch("GET", `/zones/${zn.id}/dns_records?name=${encodeURIComponent(hostname.toLowerCase())}`);
      const existing = (ex.json?.result ?? []) as Array<{ id: string; type: string; content: string }>;
      const body = { type: "CNAME", name: hostname.toLowerCase(), content: target, proxied: true, comment: "cloudflared tunnel route (c3-infra-mcp)" };
      if (existing.length && !overwrite) return `Record(s) already exist for ${hostname}: ${existing.map((r) => `${r.type} → ${r.content}`).join(", ")}. Pass overwrite=true to replace.`;
      if (existing.length > 1) return `More than one record exists for ${hostname}; fix by hand via devops.cf.api_write.`;
      const [m, p] = existing.length ? ["PUT", `/zones/${zn.id}/dns_records/${existing[0].id}`] : ["POST", `/zones/${zn.id}/dns_records`];
      return cfWrite("devops.cf.tunnel_route_dns", m, p, body, confirm);
    }),
  );

  server.tool(
    "devops.cf.tunnel_route_ip",
    "Equivalent of `cloudflared tunnel route ip add <CIDR> <tunnel>`: route a private network through a tunnel (Zero Trust private network). DRY-RUN unless confirm=true; audited. Delete with devops.cf.api_write DELETE /accounts/${account}/teamnet/routes/<route_id>.",
    {
      tunnel_id: z.string().regex(/^[0-9a-f-]{36}$/),
      network: z.string().regex(/^[0-9a-fA-F:.]+\/\d{1,3}$/).describe("CIDR, e.g. 10.0.0.0/24"),
      virtual_network_id: z.string().regex(/^[0-9a-f-]{36}$/).optional().describe("Default vnet when omitted"),
      comment: z.string().max(200).optional(),
      confirm: z.boolean().optional(),
    },
    ({ tunnel_id, network, virtual_network_id, comment, confirm }) => safeRun(() =>
      cfWrite("devops.cf.tunnel_route_ip", "POST", "/accounts/${account}/teamnet/routes",
        { network, tunnel_id, ...(virtual_network_id ? { virtual_network_id } : {}), comment: comment ?? "c3-infra-mcp" }, confirm)),
  );

  server.tool(
    "devops.cf.cloudflared_write",
    "cloudflared state-changing subcommands (tunnel create|delete|cleanup|route …|vnet add/delete). DRY-RUN unless confirm=true; audited. Needs an origin cert the MCP does not hold — prefer devops.cf.api_write / tunnel_route_* which use the API credential.",
    { command: z.string(), confirm: z.boolean().optional() },
    ({ command, confirm }) => safeRun(() => cliWrite("cloudflared", command, confirm)),
  );

  server.tool(
    "devops.cf.wrangler_write",
    "wrangler state-changing subcommands (deploy, delete, kv key put, r2 bucket create, d1 execute, …). DRY-RUN unless confirm=true; audited. login/dev/tail/secret put are refused.",
    { command: z.string(), confirm: z.boolean().optional() },
    ({ command, confirm }) => safeRun(() => cliWrite("wrangler", command, confirm)),
  );
}
