// cf-policy.ts — the pure, testable half of the Cloudflare bridge
// (obs.debug.cf_api, obs.debug.cf_cloudflared, devops.cf.*, and the
// auth/redaction used by obs.debug.vps_cloudflare / vps_wrangler).
//
// No imports on purpose: test-cf-bridge.mjs loads this file directly with
// `node --experimental-strip-types`, which cannot resolve the `.js`
// specifiers the rest of the tree uses.
//
// Three rules this file enforces:
//   1. Reads are the default. Anything that is not a GET (API) or a known
//      read-only subcommand (cloudflared / wrangler) is a WRITE, and a write
//      runs only through a devops.cf.* tool with confirm=true (audited there).
//   2. No credential ever leaves the bridge. Secret-returning endpoints are
//      refused outright; secret-shaped JSON fields and token-shaped strings
//      are redacted from every response; the live credential values are
//      scrubbed by exact match as a last line of defence.
//   3. The bridge never mints credentials: the token endpoints are blocked
//      for every method.

// ─────────────────────────────────────────────────────────────────────────────
// Auth
// ─────────────────────────────────────────────────────────────────────────────

export type CfAuth =
  | { mode: "token"; headers: Record<string, string> }
  | { mode: "global"; headers: Record<string, string> }
  | { mode: "none"; headers: Record<string, string> };

/** Global API keys are 37 lowercase hex chars; API tokens are 40 chars of [A-Za-z0-9_-]. */
export function isGlobalApiKey(v: string): boolean {
  return /^[0-9a-f]{37}$/.test(v);
}

/**
 * Pick the credential from the sops-provided env. Order:
 *   CF_API_TOKEN / CLOUDFLARE_API_TOKEN           → Bearer
 *   CF_API_KEY (+ CF_API_EMAIL)                   → X-Auth-Key/X-Auth-Email when it is
 *                                                   a global key, else Bearer (a token
 *                                                   stored under the older name)
 */
export function cfAuthFromEnv(env: Record<string, string | undefined>): CfAuth {
  const token = env.CF_API_TOKEN || env.CLOUDFLARE_API_TOKEN || "";
  if (token) return { mode: "token", headers: { Authorization: `Bearer ${token}` } };
  const key = env.CF_API_KEY || env.CLOUDFLARE_API_KEY || "";
  const email = env.CF_API_EMAIL || env.CLOUDFLARE_EMAIL || "";
  if (key && isGlobalApiKey(key)) {
    if (!email) return { mode: "none", headers: {} };
    return { mode: "global", headers: { "X-Auth-Key": key, "X-Auth-Email": email } };
  }
  if (key) return { mode: "token", headers: { Authorization: `Bearer ${key}` } };
  return { mode: "none", headers: {} };
}

/** Every credential value present in env — scrubbed from output by exact match. */
export function cfSecretValues(env: Record<string, string | undefined>): string[] {
  const names = ["CF_API_TOKEN", "CLOUDFLARE_API_TOKEN", "CF_API_KEY", "CLOUDFLARE_API_KEY", "TUNNEL_TOKEN"];
  return names.map((n) => env[n] ?? "").filter((v) => v.length >= 8);
}

// ─────────────────────────────────────────────────────────────────────────────
// Read presets (GET only). `scope` is the API-token permission the preset
// needs — reported verbatim when a call comes back 403 so the owner knows
// exactly what to add to a scoped token.
// ─────────────────────────────────────────────────────────────────────────────

export interface CfPreset {
  path: string;            // ${account} ${zone} ${id} placeholders
  scope: string;           // API-token permission name
  desc: string;
  fields?: string[];       // projection for the compact view
  needsId?: boolean;
}

const T = "Account · Cloudflare Tunnel · Read";
const ACC_APPS = "Account · Access: Apps and Policies · Read";
const ACC_TOK = "Account · Access: Service Tokens · Read";
const ACC_ORG = "Account · Access: Organizations, Identity Providers, and Groups · Read";
const ZT = "Account · Zero Trust · Read";

export const CF_READ_PRESETS: Record<string, CfPreset> = {
  "auth":               { path: "/user", scope: "User · User Details · Read (global key) / token verify", desc: "Who am I (auth mode + user/token status)", fields: ["email", "id", "status"] },
  "accounts":           { path: "/accounts?per_page=50", scope: "Account · Account Settings · Read", desc: "Accounts this credential can see", fields: ["id", "name", "type"] },
  "zones":              { path: "/zones?per_page=50", scope: "Zone · Zone · Read", desc: "Zones", fields: ["id", "name", "status", "plan.name"] },
  "dns":                { path: "/zones/${zone}/dns_records?per_page=100", scope: "Zone · DNS · Read", desc: "DNS records of a zone (id = zone name or id; default: first zone)", fields: ["id", "type", "name", "content", "proxied"] },
  "tunnels":            { path: "/accounts/${account}/cfd_tunnel?is_deleted=false&per_page=100", scope: T, desc: "cloudflared tunnel list", fields: ["id", "name", "status", "created_at", "remote_config", "connections.length"] },
  "tunnel":             { path: "/accounts/${account}/cfd_tunnel/${id}", scope: T, desc: "cloudflared tunnel info <id>", needsId: true },
  "tunnel_connections": { path: "/accounts/${account}/cfd_tunnel/${id}/connections", scope: T, desc: "Connectors of tunnel <id>", needsId: true },
  "tunnel_config":      { path: "/accounts/${account}/cfd_tunnel/${id}/configurations", scope: T, desc: "Remotely-managed ingress config of tunnel <id>", needsId: true },
  "routes":             { path: "/accounts/${account}/teamnet/routes?is_deleted=false&per_page=100", scope: T, desc: "Private network routes (tunnel route ip show)", fields: ["id", "network", "tunnel_id", "tunnel_name", "virtual_network_id", "comment"] },
  "vnets":              { path: "/accounts/${account}/teamnet/virtual_networks?is_deleted=false", scope: T, desc: "Virtual networks", fields: ["id", "name", "is_default_network", "comment"] },
  "access_apps":        { path: "/accounts/${account}/access/apps?per_page=100", scope: ACC_APPS, desc: "Access applications", fields: ["id", "name", "type", "domain", "session_duration"] },
  "access_app":         { path: "/accounts/${account}/access/apps/${id}", scope: ACC_APPS, desc: "One Access application", needsId: true },
  "access_app_policies":{ path: "/accounts/${account}/access/apps/${id}/policies", scope: ACC_APPS, desc: "Policies attached to app <id>", needsId: true, fields: ["id", "name", "decision", "precedence"] },
  "access_policies":    { path: "/accounts/${account}/access/policies?per_page=100", scope: ACC_APPS, desc: "Reusable Access policies", fields: ["id", "name", "decision", "app_count"] },
  "service_tokens":     { path: "/accounts/${account}/access/service_tokens?per_page=100", scope: ACC_TOK, desc: "Access service tokens (metadata; secrets never returned)", fields: ["id", "name", "client_id", "expires_at", "duration"] },
  "idps":               { path: "/accounts/${account}/access/identity_providers", scope: ACC_ORG, desc: "Identity providers", fields: ["id", "name", "type"] },
  "access_groups":      { path: "/accounts/${account}/access/groups?per_page=100", scope: ACC_ORG, desc: "Access groups", fields: ["id", "name"] },
  "access_org":         { path: "/accounts/${account}/access/organizations", scope: ACC_ORG, desc: "Zero Trust organization (team domain, login design)", fields: ["name", "auth_domain", "is_ui_read_only"] },
  "gateway":            { path: "/accounts/${account}/gateway", scope: ZT, desc: "Gateway account (Zero Trust enabled? gateway tag)" },
  "gateway_config":     { path: "/accounts/${account}/gateway/configuration", scope: ZT, desc: "Gateway account settings" },
  "gateway_locations":  { path: "/accounts/${account}/gateway/locations", scope: ZT, desc: "Gateway DNS locations", fields: ["id", "name", "doh_subdomain", "ip", "client_default", "networks"] },
  "gateway_rules":      { path: "/accounts/${account}/gateway/rules", scope: ZT, desc: "Gateway rules (DNS / HTTP / network)", fields: ["id", "name", "action", "filters", "enabled", "precedence", "traffic"] },
  "gateway_lists":      { path: "/accounts/${account}/gateway/lists", scope: ZT, desc: "Gateway lists", fields: ["id", "name", "type", "count"] },
  "devices":            { path: "/accounts/${account}/devices", scope: ZT, desc: "WARP devices", fields: ["id", "name", "user.email", "last_seen", "os_version"] },
  "device_policy":      { path: "/accounts/${account}/devices/policy", scope: ZT, desc: "Default WARP device settings policy" },
  "split_tunnel":       { path: "/accounts/${account}/devices/policy/exclude", scope: ZT, desc: "WARP split-tunnel exclude list" },
  "local_domains":      { path: "/accounts/${account}/devices/policy/fallback_domains", scope: ZT, desc: "WARP local domain fallback (private DNS)" },
  "workers":            { path: "/accounts/${account}/workers/scripts", scope: "Account · Workers Scripts · Read", desc: "Workers scripts", fields: ["id", "modified_on"] },
  "firewall":           { path: "/zones/${zone}/rulesets", scope: "Zone · Zone WAF · Read", desc: "Zone rulesets (WAF / custom rules)", fields: ["id", "name", "phase", "kind"] },
};

/** Required permission for a write, by path. */
export function writeScopeFor(path: string): string {
  if (/\/cfd_tunnel|\/teamnet\//.test(path)) return "Account · Cloudflare Tunnel · Edit";
  if (/\/access\/service_tokens/.test(path)) return "Account · Access: Service Tokens · Edit";
  if (/\/access\/(identity_providers|groups|organizations)/.test(path)) return "Account · Access: Organizations, Identity Providers, and Groups · Edit";
  if (/\/access\//.test(path)) return "Account · Access: Apps and Policies · Edit";
  if (/\/gateway|\/devices/.test(path)) return "Account · Zero Trust · Edit";
  if (/\/dns_records/.test(path)) return "Zone · DNS · Edit";
  if (/\/workers\//.test(path)) return "Account · Workers Scripts · Edit";
  return "(see https://developers.cloudflare.com/fundamentals/api/reference/permissions/)";
}

// ─────────────────────────────────────────────────────────────────────────────
// Path / method validation
// ─────────────────────────────────────────────────────────────────────────────

export const READ_METHODS = new Set(["GET"]);
export const WRITE_METHODS = new Set(["POST", "PUT", "PATCH", "DELETE"]);

// Endpoints that return or mint credentials. Refused for EVERY method.
const SECRET_ENDPOINTS: RegExp[] = [
  /^\/user\/tokens(\/|$|\?)(?!verify)/,            // user API tokens (list/create/roll) — verify is fine
  /^\/accounts\/[^/]+\/tokens(\/|$|\?)/,            // account API tokens
  /^\/user\/api_key/,                               // global key
  /\/cfd_tunnel\/[^/]+\/token(\/|$|\?)/,            // tunnel run token
  /\/warp_connector\/[^/]+\/token(\/|$|\?)/,
  /\/access\/service_tokens\/[^/]+\/(rotate|refresh)(\/|$|\?)/, // returns a new client_secret
  /\/access\/certificates(\/|$|\?)/,                // mTLS / SSH CA private material
  /\/access\/gateway_ca(\/|$|\?)/,
  /\/members(\/|$|\?)/,                             // account membership = privilege change
];

export type PathCheck = { ok: true; path: string } | { ok: false; reason: string };

export function validateApiPath(rawPath: string, method: string): PathCheck {
  const m = (method || "GET").toUpperCase();
  if (!READ_METHODS.has(m) && !WRITE_METHODS.has(m)) return { ok: false, reason: `method ${method} not allowed` };
  if (typeof rawPath !== "string" || rawPath.length === 0) return { ok: false, reason: "empty path" };
  if (/[\x00-\x1f\x7f]/.test(rawPath)) return { ok: false, reason: "path has control characters" };
  let p = rawPath.trim();
  if (/^https?:\/\//i.test(p)) {
    const u = p.match(/^https:\/\/api\.cloudflare\.com\/client\/v4(\/.*)$/i);
    if (!u) return { ok: false, reason: "only https://api.cloudflare.com/client/v4 paths are allowed" };
    p = u[1];
  }
  if (!p.startsWith("/")) p = "/" + p;
  if (p.length > 1024) return { ok: false, reason: "path too long" };
  if (/[\s\\#]/.test(p) || /[\x00-\x1f]/.test(p)) return { ok: false, reason: "path has whitespace or control characters" };
  const pathOnly = p.split("?")[0];
  if (pathOnly.split("/").some((seg) => seg === ".." || seg === "." || /%2e/i.test(seg) || /%2f/i.test(seg)))
    return { ok: false, reason: "path traversal / encoded separators not allowed" };
  for (const re of SECRET_ENDPOINTS) {
    if (re.test(p)) return { ok: false, reason: `endpoint returns or mints credentials (${re.source}) — refused by policy; create/rotate credentials in the dashboard and store them in sops` };
  }
  return { ok: true, path: p };
}

/** Write gating: a write runs only with confirm === true. */
export function gateWrite(method: string, confirm: unknown): { run: boolean; reason: string } {
  const m = (method || "").toUpperCase();
  if (READ_METHODS.has(m)) return { run: true, reason: "read" };
  if (!WRITE_METHODS.has(m)) return { run: false, reason: `method ${method} not allowed` };
  if (confirm === true) return { run: true, reason: "confirmed write" };
  return { run: false, reason: "dry-run: write not executed — repeat with confirm=true to apply" };
}

/** Fill ${account} ${zone} ${id} in a preset path. Ids are validated so they cannot inject path segments. */
export function fillPresetPath(tpl: string, vars: { account?: string; zone?: string; id?: string }): PathCheck {
  for (const [k, v] of Object.entries(vars)) {
    if (v !== undefined && v !== "" && !/^[A-Za-z0-9._-]{1,128}$/.test(v)) return { ok: false, reason: `invalid ${k}: ${v}` };
  }
  const missing: string[] = [];
  const out = tpl.replace(/\$\{(account|zone|id)\}/g, (_m, k: "account" | "zone" | "id") => {
    const v = vars[k];
    if (!v) missing.push(k);
    return v ?? "";
  });
  if (missing.length) return { ok: false, reason: `missing ${missing.join(", ")}` };
  return { ok: true, path: out };
}

// ─────────────────────────────────────────────────────────────────────────────
// Argument tokenizing + CLI classification (cloudflared / wrangler)
// ─────────────────────────────────────────────────────────────────────────────

/** POSIX-ish word split: whitespace splits, '…' and "…" group, quotes removed. */
export function tokenizeArgs(command: string): string[] {
  const out: string[] = [];
  let cur = "";
  let inTok = false;
  let q: string | null = null;
  for (const ch of command ?? "") {
    if (q) { if (ch === q) q = null; else cur += ch; continue; }
    if (ch === '"' || ch === "'") { q = ch; inTok = true; continue; }
    if (/\s/.test(ch)) { if (inTok) { out.push(cur); cur = ""; inTok = false; } continue; }
    cur += ch; inTok = true;
  }
  if (inTok) out.push(cur);
  return out;
}

export type CliClass = "read" | "write" | "blocked";

/** Positional words only (flags and their =values dropped) — the subcommand path. */
function verbs(argv: string[]): string[] {
  return argv.filter((a) => !a.startsWith("-")).map((a) => a.toLowerCase());
}

/**
 * cloudflared. Read: version/help, tunnel list|info, tunnel route ip show|get,
 * tunnel vnet list, access ssh-config. Blocked: anything that prints
 * or creates credentials (tunnel token, login, access login|token, service install).
 * Everything else under tunnel/access is a write.
 */
export function classifyCloudflared(argv: string[]): CliClass {
  const v = verbs(argv);
  const flags = argv.filter((a) => a.startsWith("-")).map((a) => a.toLowerCase().split("=")[0]);
  if (flags.some((f) => f === "--cred-file" || f === "--credentials-file" || f === "--credentials-contents" || f === "--token" || f === "--origincert")) return "blocked";
  if (v.length === 0) return flags.length > 0 && flags.every((f) => ["--version", "-v", "-h", "--help"].includes(f)) ? "read" : "blocked";
  const [a, b, c, d] = v;
  if (a === "version" || a === "help") return "read";
  if (a === "login" || a === "update" || a === "service" || a === "proxy-dns") return "blocked";
  if (a === "tunnel") {
    if (b === undefined || b === "help") return "read";
    if (b === "token" || b === "login" || b === "run") return "blocked";
    if (b === "list" || b === "info" || b === "ready") return "read";
    if (b === "ingress" && (c === "validate" || c === "rule")) return "read";
    if (b === "route" && c === "ip" && (d === "show" || d === "list" || d === "get")) return "read";
    if (b === "vnet" && c === "list") return "read";
    if (["create", "delete", "cleanup", "route", "vnet"].includes(b)) return "write";
    return "blocked";
  }
  if (a === "access") {
    if (b === undefined || b === "help") return "read";
    if (b === "ssh-config") return "read";
    if (b === "login" || b === "token" || b === "curl" || b === "tcp" || b === "rdp" || b === "ssh" || b === "ssh-gen") return "blocked";
    return "blocked";
  }
  return "blocked";
}

/**
 * wrangler. Read = an exact subcommand path from WRANGLER_READ (prefix match on
 * the positional words, so `kv key list --namespace-id X` is a read but
 * `d1 execute db --command list` is not). Blocked: login/logout/dev/init and
 * secret put/bulk (the value would travel on argv/stdin). Everything else is a write.
 */
const WRANGLER_READ: string[][] = [
  ["whoami"], ["help"], ["docs"],
  ["deployments", "list"], ["deployments", "status"], ["versions", "list"], ["versions", "view"],
  ["kv", "namespace", "list"], ["kv", "key", "list"], ["kv", "key", "get"],
  ["r2", "bucket", "list"], ["r2", "bucket", "info"], ["r2", "bucket", "cors", "list"], ["r2", "bucket", "domain", "list"],
  ["d1", "list"], ["d1", "info"], ["d1", "migrations", "list"],
  ["pages", "project", "list"], ["pages", "deployment", "list"],
  ["queues", "list"], ["queues", "info"], ["vectorize", "list"], ["vectorize", "get"], ["vectorize", "info"],
  ["hyperdrive", "list"], ["hyperdrive", "get"], ["secret", "list"], ["secrets-store", "store", "list"],
  ["workflows", "list"], ["workflows", "describe"], ["workflows", "instances", "list"], ["workflows", "instances", "describe"],
  ["containers", "list"], ["containers", "info"], ["dispatch-namespace", "list"], ["dispatch-namespace", "get"],
  ["ai", "models"], ["ai", "finetune", "list"], ["pipelines", "list"], ["pipelines", "get"], ["mtls-certificate", "list"],
];
const WRANGLER_BLOCKED = new Set(["login", "logout", "dev", "init", "generate", "setup", "tail"]); // tail streams forever

export function classifyWrangler(argv: string[]): CliClass {
  const v = verbs(argv);
  if (v.length === 0) {
    const flags = argv.map((a) => a.toLowerCase());
    return flags.length > 0 && flags.every((f) => ["--version", "-v", "--help", "-h"].includes(f)) ? "read" : "blocked";
  }
  if (WRANGLER_BLOCKED.has(v[0])) return "blocked";
  if ((v[0] === "secret" || v[0] === "secrets-store") && !(v[1] === "list" || (v[1] === "store" && v[2] === "list"))) return "blocked";
  if (WRANGLER_READ.some((p) => p.every((w, i) => v[i] === w))) return "read";
  return "write";
}

// ─────────────────────────────────────────────────────────────────────────────
// Redaction
// ─────────────────────────────────────────────────────────────────────────────

export const CF_REDACTED = "***REDACTED***";

// JSON keys whose VALUE is a credential. Exact-name (case-insensitive) to keep
// e.g. `token_id`, `client_id`, `tunnel_id` readable.
const SECRET_KEYS = new Set([
  "token", "value", "secret", "client_secret", "tunnel_secret", "tunnelsecret", "credentials_file",
  "credentials", "private_key", "privatekey", "password", "api_key", "apikey", "key", "cert", "certificate",
  "auth_key", "pre_shared_key", "x-auth-key", "authorization", "jwt", "access_token", "refresh_token",
]);
// `value` and `key` are only secret-shaped in some objects: we redact them only
// when the containing object also looks like a credential (has a secret-ish sibling)
// or when the string itself looks like a token. See redactCfJson.
const CONTEXT_KEYS = new Set(["value", "key"]);

/** Strings that look like credentials regardless of the key they sit under. */
const TOKENISH: RegExp[] = [
  /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g,  // JWT (Access JWTs, cf-access-token)
  /\beyJ[A-Za-z0-9+/=_-]{60,}/g,                                       // base64 JSON blob (cloudflared tunnel token {"a","t","s"})
  /-----BEGIN [A-Z ]*(PRIVATE KEY|ARGO TUNNEL TOKEN|CERTIFICATE)-----[\s\S]*?-----END [A-Z ]*-----/g,
  /\b(Bearer\s+)[A-Za-z0-9_\-.]{20,}/gi,
  /(X-Auth-Key:\s*)[0-9a-f]{37}\b/gi,
];

export function redactCfString(s: string, secrets: string[] = []): string {
  if (typeof s !== "string" || s === "") return s;
  let out = s;
  for (const v of secrets) if (v && v.length >= 8) out = out.split(v).join(CF_REDACTED);
  for (const re of TOKENISH) {
    out = out.replace(re, (m, lead) => (typeof lead === "string" && /^(Bearer\s+|X-Auth-Key:\s*)$/i.test(lead) ? `${lead}${CF_REDACTED}` : CF_REDACTED));
  }
  return out;
}

/** Deep-redact a parsed API response. Returns a new value. */
export function redactCfJson(v: unknown, secrets: string[] = [], depth = 0): unknown {
  if (depth > 40) return CF_REDACTED;
  if (typeof v === "string") return redactCfString(v, secrets);
  if (Array.isArray(v)) return v.map((x) => redactCfJson(x, secrets, depth + 1));
  if (v && typeof v === "object") {
    const obj = v as Record<string, unknown>;
    const keys = Object.keys(obj);
    const credentialish = keys.some((k) => SECRET_KEYS.has(k.toLowerCase()) && !CONTEXT_KEYS.has(k.toLowerCase()));
    const out: Record<string, unknown> = {};
    for (const k of keys) {
      const lk = k.toLowerCase();
      const val = obj[k];
      const isSecretKey = SECRET_KEYS.has(lk) && (!CONTEXT_KEYS.has(lk) || credentialish);
      if (isSecretKey && val !== null && val !== undefined && val !== "" && typeof val !== "boolean" && typeof val !== "number") {
        out[k] = CF_REDACTED;
      } else {
        out[k] = redactCfJson(val, secrets, depth + 1);
      }
    }
    return out;
  }
  return v;
}

// ─────────────────────────────────────────────────────────────────────────────
// Projection (compact view)
// ─────────────────────────────────────────────────────────────────────────────

function pick(o: any, path: string): unknown {
  let cur = o;
  for (const part of path.split(".")) {
    if (cur === null || cur === undefined) return undefined;
    if (part === "length" && Array.isArray(cur)) return cur.length;
    cur = cur[part];
  }
  return cur;
}

export function project(result: unknown, fields?: string[]): unknown {
  if (!fields || fields.length === 0) return result;
  const one = (o: any) => {
    const r: Record<string, unknown> = {};
    for (const f of fields) r[f] = pick(o, f);
    return r;
  };
  return Array.isArray(result) ? result.map(one) : result && typeof result === "object" ? one(result) : result;
}

/** Map a Cloudflare error payload to a one-line diagnosis with the scope to add. */
export function explainCfError(status: number, errors: Array<{ code?: number; message?: string }> | undefined, scope: string): string {
  const msgs = (errors ?? []).map((e) => `${e.code ?? "?"}: ${e.message ?? ""}`).join(" | ");
  if ((errors ?? []).some((e) => /not_enabled|not enabled/i.test(e.message ?? "")))
    return `HTTP ${status} ${msgs}\n→ Zero Trust / Access is not enabled on this account. The owner must open https://one.dash.cloudflare.com/ once, pick a team name and the Free plan. This is not a token-scope problem.`;
  if (status === 403 || (errors ?? []).some((e) => e.code === 10000 || e.code === 9109))
    return `HTTP ${status} ${msgs}\n→ the credential lacks: ${scope}`;
  if (status === 401) return `HTTP ${status} ${msgs}\n→ credential rejected (expired/revoked?)`;
  return `HTTP ${status} ${msgs}`;
}
