import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { XMLParser } from "fast-xml-parser";
import { registry } from "../../registry/index.js";
import { searchPublicRegistry, getPublicServer } from "../../registry/public-registry.js";

// ── Authelia ─────────────────────────────────────────────────────────────────
const AUTHELIA_BASE = "http://10.0.0.1:9091";
function autheliaApi(path: string, extraHeaders?: Record<string, string>): string {
  const result = rawHttpRequest("GET", `${AUTHELIA_BASE}${path}`, undefined, 10_000, extraHeaders);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Dagu ──────────────────────────────────────────────────────────────────────
function resolveDagu(): { base: string; path: string } {
  const envBase = process.env.DAGU_API_URL;
  const envPath = process.env.DAGU_API_PATH;
  const gitBase = process.env.GIT_BASE ?? join(homedir(), "git");
  const candidates = [
    "/app/build-c3-services-mcp.json",
    join(gitBase, "cloud", "1_configs", "dist", "build-c3-services-mcp.json"),
    "/app/_cloud-data-consolidated.json",
    join(gitBase, "cloud", "1_configs", "dist", "_cloud-data-consolidated.json"),
  ];
  let base = "";
  let path = "";
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try {
      const d = JSON.parse(readFileSync(p, "utf-8"));
      const svc = d.services?.dagu;
      if (!svc) continue;
      const ip = svc.ip ?? (svc.vm ? d.vms?.[svc.vm]?.wg_ip : undefined);
      const port = svc.ports?.app ?? svc.port;
      if (ip && port) base = `http://${ip}:${port}`;
      const bp = svc.api?.base_path;
      if (typeof bp === "string" && bp.startsWith("/")) path = bp;
      if (base) break;
    } catch { /* skip */ }
  }
  return {
    base: envBase || base || "http://10.0.0.6:8070",
    path: envPath || path || "/api/v1",
  };
}
const { base: DAGU_BASE, path: DAGU_PATH } = resolveDagu();
const DAGU_AUTH = process.env.DAGU_BASIC_AUTH ?? "";
function daguHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};
  if (DAGU_AUTH) headers["Authorization"] = `Basic ${Buffer.from(DAGU_AUTH).toString("base64")}`;
  return headers;
}

// ── Matomo ────────────────────────────────────────────────────────────────────
const MATOMO_BASE = "http://10.0.0.4:8080";
function matomoApiCall(method: string, params: Record<string, string> = {}): string {
  const token = process.env.MATOMO_API_TOKEN ?? "";
  const qs = new URLSearchParams({ module: "API", method, format: "JSON", token_auth: token, ...params });
  const result = rawHttpRequest("GET", `${MATOMO_BASE}/?${qs.toString()}`);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── NocoDB ────────────────────────────────────────────────────────────────────
const NOCODB_BASE = "http://10.0.0.6:8085";
function nocoApi(method: string, path: string, body?: string): string {
  const token = process.env.NOCODB_API_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["xc-token"] = token;
  const result = rawHttpRequest(method, `${NOCODB_BASE}${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Ntfy ──────────────────────────────────────────────────────────────────────
const NTFY_BASE = "http://10.0.0.6:8090";
const ntfyToken = () => process.env.NTFY_TOKEN ?? "";
function ntfyHeaders(): Record<string, string> | undefined {
  const token = ntfyToken();
  return token ? { Authorization: `Bearer ${token}` } : undefined;
}
function ntfyGet(path: string): string {
  const result = rawHttpRequest("GET", `${NTFY_BASE}${path}`, undefined, 10_000, ntfyHeaders());
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Syncthing ─────────────────────────────────────────────────────────────────
const SYNCTHING_BASE = "http://10.0.0.3:8384";
function syncthingGet(path: string): string {
  const apiKey = process.env.SYNCTHING_API_KEY ?? "";
  const result = rawHttpRequest("GET", `${SYNCTHING_BASE}${path}`, undefined, 10_000, { "X-API-Key": apiKey });
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Etherpad ──────────────────────────────────────────────────────────────────
const ETHERPAD_BASE = "http://10.0.0.6:3012";
function epApi(method: string, params: Record<string, string> = {}): string {
  const apiKey = process.env.ETHERPAD_API_KEY ?? "";
  const qs = new URLSearchParams({ apikey: apiKey, ...params });
  const result = rawHttpRequest("GET", `${ETHERPAD_BASE}/api/1.3.0/${method}?${qs}`, undefined, 15_000);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Filebrowser ───────────────────────────────────────────────────────────────
const FB_BASE = "http://10.0.0.6:3015";
function fbApi(method: string, path: string, body?: string): string {
  const token = process.env.FILEBROWSER_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["X-Auth"] = token;
  const result = rawHttpRequest(method, `${FB_BASE}/api${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Gitea ─────────────────────────────────────────────────────────────────────
const GITEA_BASE = "http://10.0.0.6:3017";
function giteaApi(method: string, path: string, body?: string): string {
  const token = process.env.GITEA_API_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `token ${token}`;
  const result = rawHttpRequest(method, `${GITEA_BASE}/api/v1${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Grist ─────────────────────────────────────────────────────────────────────
const GRIST_BASE = "http://10.0.0.6:3011";
function gristApi(method: string, path: string, body?: string): string {
  const token = process.env.GRIST_API_KEY ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${GRIST_BASE}/api${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── HedgeDoc ──────────────────────────────────────────────────────────────────
const HEDGEDOC_BASE = "http://10.0.0.6:3018";
function hdApi(method: string, path: string, body?: string): string {
  const token = process.env.HEDGEDOC_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${HEDGEDOC_BASE}/api/v2${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── PhotoPrism ────────────────────────────────────────────────────────────────
const PHOTOPRISM_BASE = "http://10.0.0.6:3013";
function ppApi(method: string, path: string, body?: string): string {
  const token = process.env.PHOTOPRISM_SESSION_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["X-Session-ID"] = token;
  const result = rawHttpRequest(method, `${PHOTOPRISM_BASE}/api/v1${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Radicale ──────────────────────────────────────────────────────────────────
const RADICALE_BASE = "http://10.0.0.6:5232";
const PROPFIND_BODY = `<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:resourcetype/>
    <D:getcontenttype/>
  </D:prop>
</D:propfind>`;
function radicaleRequest(method: string, path: string, body?: string): string {
  const user = process.env.RADICALE_USER ?? "";
  const pass = process.env.RADICALE_PASSWORD ?? "";
  const auth = Buffer.from(`${user}:${pass}`).toString("base64");
  const headers: Record<string, string> = { Authorization: `Basic ${auth}` };
  if (body) headers["Content-Type"] = "application/xml; charset=utf-8";
  const result = rawHttpRequest(method, `${RADICALE_BASE}${path}`, body, 10_000, headers);
  if (!result.ok) return JSON.stringify({ error: result.error, status: result.status }, null, 2);
  if (typeof result.raw === "string" && result.raw.includes("<?xml")) {
    const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: "@_" });
    return JSON.stringify(parser.parse(result.raw), null, 2);
  }
  return JSON.stringify(result.data, null, 2);
}

// ── SnappyMail ────────────────────────────────────────────────────────────────
const SNAPPYMAIL_BASE = "http://10.0.0.3:8888";

// ── Vaultwarden ───────────────────────────────────────────────────────────────
const VW_BASE = "http://10.0.0.6:8880";
function vwApi(path: string): string {
  const token = process.env.VAULTWARDEN_ADMIN_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest("GET", `${VW_BASE}${path}`, undefined, 10_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Umami ─────────────────────────────────────────────────────────────────────
const UMAMI_BASE = "http://10.0.0.4:3000";
function umamiApi(method: string, path: string, body?: string): string {
  const token = process.env.UMAMI_API_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${UMAMI_BASE}/api${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Rig ───────────────────────────────────────────────────────────────────────
const RIG_HEAVY = "http://10.0.0.6:8090";
const RIG_LIGHT = "http://10.0.0.6:8091";
function rigApi(method: string, base: string, path: string, body?: string): string {
  const result = rawHttpRequest(method, `${base}${path}`, body, 30_000);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Scrappers ─────────────────────────────────────────────────────────────────
const SCRAPPERS_BASE = "http://10.0.0.6:3020/scrappers";
function scrappersApi(method: string, path: string, body?: string): string {
  const result = rawHttpRequest(method, `${SCRAPPERS_BASE}${path}`, body, 120_000, {});
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

// ── Discovery helpers (for services.meta) ─────────────────────────────────────
const NATIVE_WRAPPED: Set<string> = new Set([
  "authelia", "scrappers-api", "dagu", "etherpad", "filebrowser",
  "gitea", "grist", "hedgedoc", "matomo", "nocodb",
  "ntfy", "ollama", "ollama-hai", "photoprism", "radicale",
  "rig-agentic-hai-1.5bq4", "rig-agentic-sonn-14bq8", "snappymail",
  "syncthing", "umami", "vaultwarden",
]);
const PROXIED_MCPS: Set<string> = new Set([
  "cloud-cgc-mcp", "mattermost-mcp", "mail-mcp", "google-workspace-mcp",
  "chat-mattermost",
]);
const SELF_SERVICES: Set<string> = new Set([
  "c3-services-mcp", "c3-services-api", "c3-infra-mcp", "c3-infra-api",
  "c3-diego-personal-data-mcp",
]);
const INFRA_NO_API: Set<string> = new Set([
  "caddy", "caddy-l4-image", "hickory-dns", "introspect-proxy",
  "cloudflare", "cloudflare-worker", "redis", "postlite",
  "fluent-bit",
  "syslog-forwarder", "alerts-api", "cloud-spec",
  "backup-borg", "backup-bup",
  "photos-webhook", "orchestrator", "kg-graph",
  "code-server",
  "stalwart",
  "gcloud",
  "db-agent",
  "ollama-arm",
  "http-to-smtp-proxy-api",
  "revealmd",
]);

interface TopoService {
  vm?: string;
  domain?: string;
  port?: number;
  category?: string;
  enabled?: boolean;
  description?: string;
}
interface TopoData {
  services: Record<string, TopoService>;
}
function loadTopology(): TopoData | null {
  const gitBase = process.env.GIT_BASE ?? join(homedir(), "git");
  const candidates = [
    "/app/build-c3-services-mcp.json",
    join(gitBase, "cloud", "1_configs", "dist", "build-c3-services-mcp.json"),
    "/app/_cloud-data-consolidated.json",
    join(gitBase, "cloud", "1_configs", "dist", "_cloud-data-consolidated.json"),
  ];
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try { return JSON.parse(readFileSync(p, "utf-8")) as TopoData; }
    catch { /* skip */ }
  }
  return null;
}

export function registerMetaTools(server: McpServer) {

  // ── 1. services.authelia ───────────────────────────────────────────────────
  server.tool("services.authelia", {
    method: z.enum(["config", "health", "jwks", "state", "user_info"]).describe("Authelia operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method, params }) => {
    const p = (params ?? {}) as any;
    switch (method) {
      case "health":
        return { content: [{ type: "text" as const, text: autheliaApi("/api/health") }] };
      case "state":
        return { content: [{ type: "text" as const, text: autheliaApi("/api/state") }] };
      case "config":
        return { content: [{ type: "text" as const, text: autheliaApi("/.well-known/openid-configuration") }] };
      case "jwks":
        return { content: [{ type: "text" as const, text: autheliaApi("/jwks.json") }] };
      case "user_info":
        return { content: [{ type: "text" as const, text: autheliaApi("/api/oidc/userinfo", { Authorization: `Bearer ${p.token}` }) }] };
      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });

  // ── 2. services.dagu ──────────────────────────────────────────────────────
  server.tool("services.dagu", {
    method: z.enum(["list", "trigger"]).describe("Dagu operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method, params }) => {
    const p = (params ?? {}) as any;
    switch (method) {
      case "list": {
        const result = rawHttpRequest("GET", `${DAGU_BASE}${DAGU_PATH}/dags`, undefined, 10000, daguHeaders());
        return { content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2) }] };
      }
      case "trigger": {
        const body = p.params ? JSON.stringify({ params: p.params }) : undefined;
        const result = rawHttpRequest("POST", `${DAGU_BASE}${DAGU_PATH}/dags/${p.dag_id}/start`, body, 15000, daguHeaders());
        return { content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2) }] };
      }
      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });

  // ── 3. services.matomo ────────────────────────────────────────────────────
  server.tool("services.matomo", {
    method: z.enum(["actions", "live", "referrers", "sites", "visits"]).describe("Matomo operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method, params }) => {
    const p = (params ?? {}) as any;
    switch (method) {
      case "visits":
        return { content: [{ type: "text" as const, text: matomoApiCall("VisitsSummary.get", { idSite: p.idSite ?? "1", period: p.period ?? "day", date: p.date ?? "today" }) }] };
      case "sites":
        return { content: [{ type: "text" as const, text: matomoApiCall("SitesManager.getAllSites") }] };
      case "actions":
        return { content: [{ type: "text" as const, text: matomoApiCall("Actions.get", { idSite: p.idSite ?? "1", period: p.period ?? "day", date: p.date ?? "today" }) }] };
      case "referrers":
        return { content: [{ type: "text" as const, text: matomoApiCall("Referrers.get", { idSite: p.idSite ?? "1", period: p.period ?? "day", date: p.date ?? "today" }) }] };
      case "live":
        return { content: [{ type: "text" as const, text: matomoApiCall("Live.getLastVisitsDetails", { idSite: p.idSite ?? "1", period: p.period ?? "day", date: p.date ?? "today" }) }] };
      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });

  // ── 4. services.nocodb ────────────────────────────────────────────────────
  server.tool("services.nocodb", {
    method: z.enum(["bases", "row_create", "row_delete", "rows", "row_update", "table_info", "tables"]).describe("NocoDB operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method, params }) => {
    const p = (params ?? {}) as any;
    switch (method) {
      case "bases":
        return { content: [{ type: "text" as const, text: nocoApi("GET", "/api/v2/meta/bases") }] };
      case "tables":
        return { content: [{ type: "text" as const, text: nocoApi("GET", `/api/v2/meta/bases/${encodeURIComponent(p.base_id)}/tables`) }] };
      case "rows": {
        const qp = new URLSearchParams();
        if (p.limit) qp.set("limit", String(p.limit));
        if (p.offset) qp.set("offset", String(p.offset));
        if (p.where) qp.set("where", p.where);
        if (p.sort) qp.set("sort", p.sort);
        return { content: [{ type: "text" as const, text: nocoApi("GET", `/api/v2/tables/${encodeURIComponent(p.table_id)}/records?${qp}`) }] };
      }
      case "row_create":
        return { content: [{ type: "text" as const, text: nocoApi("POST", `/api/v2/tables/${encodeURIComponent(p.table_id)}/records`, p.data) }] };
      case "row_update":
        return { content: [{ type: "text" as const, text: nocoApi("PATCH", `/api/v2/tables/${encodeURIComponent(p.table_id)}/records`, JSON.stringify([{ Id: p.row_id, ...JSON.parse(p.data) }])) }] };
      case "row_delete":
        return { content: [{ type: "text" as const, text: nocoApi("DELETE", `/api/v2/tables/${encodeURIComponent(p.table_id)}/records`, JSON.stringify([{ Id: p.row_id }])) }] };
      case "table_info":
        return { content: [{ type: "text" as const, text: nocoApi("GET", `/api/v2/meta/tables/${encodeURIComponent(p.table_id)}`) }] };
      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });

  // ── 5. services.ntfy ─────────────────────────────────────────────────────
  server.tool("services.ntfy", {
    method: z.enum(["health", "publish", "read", "stats", "tier"]).describe("Ntfy operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method, params }) => {
    const p = (params ?? {}) as any;
    switch (method) {
      case "health":
        return { content: [{ type: "text" as const, text: ntfyGet("/v1/health") }] };
      case "stats":
        return { content: [{ type: "text" as const, text: ntfyGet("/v1/stats") }] };
      case "tier":
        return { content: [{ type: "text" as const, text: ntfyGet("/v1/account") }] };
      case "read": {
        const result = rawHttpRequest("GET", `${NTFY_BASE}/${encodeURIComponent(p.topic)}/json?poll=1&since=${encodeURIComponent(p.since ?? "24h")}`, undefined, 10_000, ntfyHeaders());
        if (!result.ok) return { content: [{ type: "text" as const, text: JSON.stringify({ error: result.error }, null, 2) }] };
        const messages = (result.raw ?? "").split("\n").filter(Boolean).map((line) => { try { return JSON.parse(line); } catch { return line; } });
        return { content: [{ type: "text" as const, text: JSON.stringify(messages, null, 2) }] };
      }
      case "publish": {
        const payload: Record<string, unknown> = { topic: p.topic, message: p.message };
        if (p.title) payload.title = p.title;
        if (p.priority) payload.priority = p.priority;
        if (p.tags) payload.tags = p.tags;
        if (p.click) payload.click = p.click;
        if (p.attach) payload.attach = p.attach;
        if (p.delay) payload.delay = p.delay;
        if (p.actions) { try { payload.actions = JSON.parse(p.actions); } catch { payload.actions = p.actions; } }
        const result = rawHttpRequest("POST", NTFY_BASE, JSON.stringify(payload), 10_000, ntfyHeaders());
        return { content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }] };
      }
      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });

  // ── 6. services.syncthing ─────────────────────────────────────────────────
  server.tool("services.syncthing", {
    method: z.enum(["config", "devices", "folders", "status"]).describe("Syncthing operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method }) => {
    switch (method) {
      case "status":
        return { content: [{ type: "text" as const, text: syncthingGet("/rest/system/status") }] };
      case "config":
        return { content: [{ type: "text" as const, text: syncthingGet("/rest/config") }] };
      case "folders":
        return { content: [{ type: "text" as const, text: syncthingGet("/rest/config/folders") }] };
      case "devices":
        return { content: [{ type: "text" as const, text: syncthingGet("/rest/system/connections") }] };
      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });

  // ── 7. services.user_apps ─────────────────────────────────────────────────
  server.tool("services.user_apps", {
    method: z.enum([
      "etherpad.pads", "etherpad.pad_text", "etherpad.pad_html", "etherpad.pad_create",
      "etherpad.pad_set_text", "etherpad.pad_delete", "etherpad.pad_revisions",
      "etherpad.pad_authors", "etherpad.pad_users",
      "filebrowser.ls", "filebrowser.info", "filebrowser.search", "filebrowser.mkdir",
      "filebrowser.delete", "filebrowser.move", "filebrowser.shares",
      "filebrowser.share_create", "filebrowser.usage",
      "gitea.repos", "gitea.repo_detail", "gitea.issues", "gitea.issue_create",
      "gitea.pulls", "gitea.users", "gitea.orgs", "gitea.releases",
      "grist.orgs", "grist.docs", "grist.tables", "grist.records",
      "grist.record_create", "grist.record_update", "grist.columns",
      "hedgedoc.notes", "hedgedoc.note_detail", "hedgedoc.note_content",
      "hedgedoc.note_create", "hedgedoc.note_delete", "hedgedoc.me", "hedgedoc.history",
      "photoprism.status", "photoprism.photos", "photoprism.photo_detail",
      "photoprism.albums", "photoprism.album_photos", "photoprism.labels",
      "photoprism.faces", "photoprism.stats",
      "radicale.calendars", "radicale.contacts", "radicale.events",
      "snappymail.health", "snappymail.domains", "snappymail.domain_config",
      "vaultwarden.health", "vaultwarden.status", "vaultwarden.users", "vaultwarden.orgs",
      "umami.websites", "umami.website_stats", "umami.pageviews", "umami.metrics",
      "umami.active", "umami.events",
      "rig.status", "rig.health", "rig.run", "rig.tasks", "rig.task_detail",
      "scrappers.health", "scrappers.targets", "scrappers.scrape", "scrappers.run",
    ]).describe("User app operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method, params }) => {
    const p = (params ?? {}) as any;
    switch (method) {
      // ── Etherpad ──────────────────────────────────────────────────────────
      case "etherpad.pads":
        return { content: [{ type: "text" as const, text: epApi("listAllPads") }] };
      case "etherpad.pad_text":
        return { content: [{ type: "text" as const, text: epApi("getText", { padID: p.pad_id }) }] };
      case "etherpad.pad_html":
        return { content: [{ type: "text" as const, text: epApi("getHTML", { padID: p.pad_id }) }] };
      case "etherpad.pad_create": {
        const ep_params: Record<string, string> = { padID: p.pad_id };
        if (p.text) ep_params.text = p.text;
        return { content: [{ type: "text" as const, text: epApi("createPad", ep_params) }] };
      }
      case "etherpad.pad_set_text":
        return { content: [{ type: "text" as const, text: epApi("setText", { padID: p.pad_id, text: p.text }) }] };
      case "etherpad.pad_delete":
        return { content: [{ type: "text" as const, text: epApi("deletePad", { padID: p.pad_id }) }] };
      case "etherpad.pad_revisions":
        return { content: [{ type: "text" as const, text: epApi("getRevisionsCount", { padID: p.pad_id }) }] };
      case "etherpad.pad_authors":
        return { content: [{ type: "text" as const, text: epApi("listAuthorsOfPad", { padID: p.pad_id }) }] };
      case "etherpad.pad_users":
        return { content: [{ type: "text" as const, text: epApi("padUsersCount", { padID: p.pad_id }) }] };

      // ── Filebrowser ───────────────────────────────────────────────────────
      case "filebrowser.ls":
        return { content: [{ type: "text" as const, text: fbApi("GET", `/resources${(p.path ?? "/").startsWith("/") ? (p.path ?? "/") : `/${p.path ?? "/"}`}`) }] };
      case "filebrowser.info":
        return { content: [{ type: "text" as const, text: fbApi("GET", `/resources${(p.path ?? "").startsWith("/") ? p.path : `/${p.path}`}?checksum=md5`) }] };
      case "filebrowser.search":
        return { content: [{ type: "text" as const, text: fbApi("GET", `/search${(p.path ?? "/").startsWith("/") ? (p.path ?? "/") : `/${p.path ?? "/"}`}?query=${encodeURIComponent(p.query ?? "")}`) }] };
      case "filebrowser.mkdir":
        return { content: [{ type: "text" as const, text: fbApi("POST", `/resources${(p.path ?? "").startsWith("/") ? p.path : `/${p.path}`}/`) }] };
      case "filebrowser.delete":
        return { content: [{ type: "text" as const, text: fbApi("DELETE", `/resources${(p.path ?? "").startsWith("/") ? p.path : `/${p.path}`}`) }] };
      case "filebrowser.move":
        return { content: [{ type: "text" as const, text: fbApi("PATCH", `/resources${(p.src ?? "").startsWith("/") ? p.src : `/${p.src}`}`, JSON.stringify({ action: "rename", destination: p.dst })) }] };
      case "filebrowser.shares":
        return { content: [{ type: "text" as const, text: fbApi("GET", "/shares") }] };
      case "filebrowser.share_create": {
        const fb_payload: Record<string, unknown> = { path: p.path };
        if (p.expires) fb_payload.expires = p.expires;
        if (p.password) fb_payload.password = p.password;
        return { content: [{ type: "text" as const, text: fbApi("POST", "/shares", JSON.stringify(fb_payload)) }] };
      }
      case "filebrowser.usage":
        return { content: [{ type: "text" as const, text: fbApi("GET", "/usage") }] };

      // ── Gitea ─────────────────────────────────────────────────────────────
      case "gitea.repos": {
        const owner = p.owner as string | undefined;
        return { content: [{ type: "text" as const, text: owner
          ? giteaApi("GET", `/repos/search?q=&owner=${encodeURIComponent(owner)}&limit=${p.limit ?? 20}`)
          : giteaApi("GET", `/repos/search?limit=${p.limit ?? 20}`) }] };
      }
      case "gitea.repo_detail":
        return { content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(p.owner)}/${encodeURIComponent(p.repo)}`) }] };
      case "gitea.issues":
        return { content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(p.owner)}/${encodeURIComponent(p.repo)}/issues?state=${p.state ?? "open"}&limit=${p.limit ?? 20}&type=issues`) }] };
      case "gitea.issue_create": {
        const g_payload: Record<string, unknown> = { title: p.title };
        if (p.body) g_payload.body = p.body;
        if (p.labels) g_payload.labels = p.labels;
        return { content: [{ type: "text" as const, text: giteaApi("POST", `/repos/${encodeURIComponent(p.owner)}/${encodeURIComponent(p.repo)}/issues`, JSON.stringify(g_payload)) }] };
      }
      case "gitea.pulls":
        return { content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(p.owner)}/${encodeURIComponent(p.repo)}/pulls?state=${p.state ?? "open"}`) }] };
      case "gitea.users":
        return { content: [{ type: "text" as const, text: giteaApi("GET", `/users/search?q=${encodeURIComponent(p.q ?? "")}&limit=${p.limit ?? 10}`) }] };
      case "gitea.orgs":
        return { content: [{ type: "text" as const, text: giteaApi("GET", "/user/orgs") }] };
      case "gitea.releases":
        return { content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(p.owner)}/${encodeURIComponent(p.repo)}/releases`) }] };

      // ── Grist ─────────────────────────────────────────────────────────────
      case "grist.orgs":
        return { content: [{ type: "text" as const, text: gristApi("GET", "/orgs") }] };
      case "grist.docs":
        return { content: [{ type: "text" as const, text: gristApi("GET", `/orgs/${encodeURIComponent(p.org_id ?? "current")}/workspaces`) }] };
      case "grist.tables":
        return { content: [{ type: "text" as const, text: gristApi("GET", `/docs/${encodeURIComponent(p.doc_id)}/tables`) }] };
      case "grist.records": {
        const gr_params = new URLSearchParams({ limit: String(p.limit ?? 50) });
        if (p.filter) gr_params.set("filter", p.filter);
        return { content: [{ type: "text" as const, text: gristApi("GET", `/docs/${encodeURIComponent(p.doc_id)}/tables/${encodeURIComponent(p.table_id)}/records?${gr_params}`) }] };
      }
      case "grist.record_create":
        return { content: [{ type: "text" as const, text: gristApi("POST", `/docs/${encodeURIComponent(p.doc_id)}/tables/${encodeURIComponent(p.table_id)}/records`, p.records) }] };
      case "grist.record_update":
        return { content: [{ type: "text" as const, text: gristApi("PATCH", `/docs/${encodeURIComponent(p.doc_id)}/tables/${encodeURIComponent(p.table_id)}/records`, p.records) }] };
      case "grist.columns":
        return { content: [{ type: "text" as const, text: gristApi("GET", `/docs/${encodeURIComponent(p.doc_id)}/tables/${encodeURIComponent(p.table_id)}/columns`) }] };

      // ── HedgeDoc ──────────────────────────────────────────────────────────
      case "hedgedoc.notes":
        return { content: [{ type: "text" as const, text: hdApi("GET", "/me/notes") }] };
      case "hedgedoc.note_detail":
        return { content: [{ type: "text" as const, text: hdApi("GET", `/notes/${encodeURIComponent(p.id)}`) }] };
      case "hedgedoc.note_content":
        return { content: [{ type: "text" as const, text: hdApi("GET", `/notes/${encodeURIComponent(p.id)}/content`) }] };
      case "hedgedoc.note_create": {
        const hd_payload: Record<string, unknown> = { content: p.content };
        if (p.alias) hd_payload.alias = p.alias;
        return { content: [{ type: "text" as const, text: hdApi("POST", "/notes", JSON.stringify(hd_payload)) }] };
      }
      case "hedgedoc.note_delete":
        return { content: [{ type: "text" as const, text: hdApi("DELETE", `/notes/${encodeURIComponent(p.id)}`) }] };
      case "hedgedoc.me":
        return { content: [{ type: "text" as const, text: hdApi("GET", "/me") }] };
      case "hedgedoc.history":
        return { content: [{ type: "text" as const, text: hdApi("GET", "/me/history") }] };

      // ── PhotoPrism ────────────────────────────────────────────────────────
      case "photoprism.status":
        return { content: [{ type: "text" as const, text: ppApi("GET", "/status") }] };
      case "photoprism.photos": {
        const pp_params = new URLSearchParams({
          q: p.q ?? "",
          count: String(p.count ?? 20),
          offset: String(p.offset ?? 0),
          order: p.order ?? "newest",
        });
        return { content: [{ type: "text" as const, text: ppApi("GET", `/photos?${pp_params}`) }] };
      }
      case "photoprism.photo_detail":
        return { content: [{ type: "text" as const, text: ppApi("GET", `/photos/${encodeURIComponent(p.uid)}`) }] };
      case "photoprism.albums":
        return { content: [{ type: "text" as const, text: ppApi("GET", `/albums?count=${p.count ?? 20}&q=${encodeURIComponent(p.q ?? "")}`) }] };
      case "photoprism.album_photos":
        return { content: [{ type: "text" as const, text: ppApi("GET", `/albums/${encodeURIComponent(p.uid)}/photos?count=${p.count ?? 50}`) }] };
      case "photoprism.labels":
        return { content: [{ type: "text" as const, text: ppApi("GET", `/labels?count=${p.count ?? 50}`) }] };
      case "photoprism.faces":
        return { content: [{ type: "text" as const, text: ppApi("GET", `/faces?count=${p.count ?? 50}`) }] };
      case "photoprism.stats":
        return { content: [{ type: "text" as const, text: ppApi("GET", "/stats") }] };

      // ── Radicale ──────────────────────────────────────────────────────────
      case "radicale.calendars": {
        const rad_user = process.env.RADICALE_USER ?? "";
        return { content: [{ type: "text" as const, text: radicaleRequest("PROPFIND", `/${rad_user}/`, PROPFIND_BODY) }] };
      }
      case "radicale.contacts": {
        const rad_user = process.env.RADICALE_USER ?? "";
        return { content: [{ type: "text" as const, text: radicaleRequest("PROPFIND", `/${rad_user}/`, PROPFIND_BODY) }] };
      }
      case "radicale.events": {
        const rad_user = process.env.RADICALE_USER ?? "";
        return { content: [{ type: "text" as const, text: radicaleRequest("PROPFIND", `/${rad_user}/${p.collection}/`, PROPFIND_BODY) }] };
      }

      // ── SnappyMail ────────────────────────────────────────────────────────
      case "snappymail.health": {
        const result = rawHttpRequest("GET", `${SNAPPYMAIL_BASE}/`, undefined, 10_000);
        const version = (result.raw ?? "").match(/snappymail\/v\/([\d.]+)/)?.[1] ?? "unknown";
        return { content: [{ type: "text" as const, text: JSON.stringify({ healthy: result.ok, status: result.status, version }, null, 2) }] };
      }
      case "snappymail.domains": {
        const { spawnSync } = await import("node:child_process");
        const proc = spawnSync("ssh", ["oci-mail", "docker exec snappymail find /var/lib/snappymail/_data_/_default_/domains -name '*.ini' -exec basename {} \\;"], {
          timeout: 10_000, encoding: "utf-8",
        });
        const domains = (proc.stdout ?? "").trim().split("\n").filter(Boolean).map((f: string) => f.replace(".ini", ""));
        return { content: [{ type: "text" as const, text: JSON.stringify({ domains }, null, 2) }] };
      }
      case "snappymail.domain_config": {
        const { spawnSync } = await import("node:child_process");
        const proc = spawnSync("ssh", ["oci-mail", "docker exec snappymail cat /var/lib/snappymail/_data_/_default_/domains/diegonmarcos.com.ini"], {
          timeout: 10_000, encoding: "utf-8",
        });
        return { content: [{ type: "text" as const, text: proc.stdout?.trim() || proc.stderr || "no config found" }] };
      }

      // ── Vaultwarden ───────────────────────────────────────────────────────
      case "vaultwarden.health":
        return { content: [{ type: "text" as const, text: vwApi("/alive") }] };
      case "vaultwarden.status":
        return { content: [{ type: "text" as const, text: vwApi("/admin/status") }] };
      case "vaultwarden.users":
        return { content: [{ type: "text" as const, text: vwApi("/admin/users") }] };
      case "vaultwarden.orgs":
        return { content: [{ type: "text" as const, text: vwApi("/admin/organizations") }] };

      // ── Umami ─────────────────────────────────────────────────────────────
      case "umami.websites":
        return { content: [{ type: "text" as const, text: umamiApi("GET", "/websites") }] };
      case "umami.website_stats":
        return { content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(p.website_id)}/stats?startAt=${encodeURIComponent(p.start_at)}&endAt=${encodeURIComponent(p.end_at)}`) }] };
      case "umami.pageviews":
        return { content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(p.website_id)}/pageviews?startAt=${encodeURIComponent(p.start_at)}&endAt=${encodeURIComponent(p.end_at)}&unit=${p.unit ?? "day"}`) }] };
      case "umami.metrics":
        return { content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(p.website_id)}/metrics?startAt=${encodeURIComponent(p.start_at)}&endAt=${encodeURIComponent(p.end_at)}&type=${p.type}&limit=${p.limit ?? 20}`) }] };
      case "umami.active":
        return { content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(p.website_id)}/active`) }] };
      case "umami.events":
        return { content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(p.website_id)}/events?startAt=${encodeURIComponent(p.start_at)}&endAt=${encodeURIComponent(p.end_at)}`) }] };

      // ── Rig ───────────────────────────────────────────────────────────────
      case "rig.status":
        return { content: [{ type: "text" as const, text: rigApi("GET", p.instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/api/status") }] };
      case "rig.health":
        return { content: [{ type: "text" as const, text: rigApi("GET", p.instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/health") }] };
      case "rig.run":
        return { content: [{ type: "text" as const, text: rigApi("POST", p.instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/agent/run", JSON.stringify({ task: p.task, max_turns: p.max_turns ?? 15 })) }] };
      case "rig.tasks":
        return { content: [{ type: "text" as const, text: rigApi("GET", p.instance === "light" ? RIG_LIGHT : RIG_HEAVY, "/agent/tasks") }] };
      case "rig.task_detail":
        return { content: [{ type: "text" as const, text: rigApi("GET", p.instance === "light" ? RIG_LIGHT : RIG_HEAVY, `/agent/tasks/${encodeURIComponent(p.id)}`) }] };

      // ── Scrappers ─────────────────────────────────────────────────────────
      case "scrappers.health":
        return { content: [{ type: "text" as const, text: scrappersApi("GET", "/health") }] };
      case "scrappers.targets":
        return { content: [{ type: "text" as const, text: scrappersApi("GET", "/targets") }] };
      case "scrappers.scrape": {
        const body = JSON.stringify(Object.fromEntries(
          Object.entries(p as Record<string, unknown>).filter(([k, v]) => k !== "platform" && v != null)
        ));
        return { content: [{ type: "text" as const, text: scrappersApi("POST", `/scrape/${p.platform}`, body) }] };
      }
      case "scrappers.run":
        return { content: [{ type: "text" as const, text: scrappersApi("POST", `/run/${encodeURIComponent(p.target_id)}`) }] };

      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });

  // ── 8. services.meta ─────────────────────────────────────────────────────
  server.tool("services.meta", {
    method: z.enum([
      "discovery.drift",
      "proxy.api_call",
      "registry.mcp_get",
      "registry.mcp_search",
      "registry.services_info",
      "registry.services_list",
      "registry.services_spec",
    ]).describe("Meta operation"),
    params: z.record(z.unknown()).optional().describe("Operation parameters"),
  }, async ({ method, params }) => {
    const p = (params ?? {}) as any;
    switch (method) {
      case "discovery.drift": {
        const topo = loadTopology();
        if (!topo) {
          return { content: [{ type: "text" as const, text: "ERROR: build-c3-services-mcp.json not found" }], isError: true };
        }
        const allServices = Object.keys(topo.services).sort();
        const covered: { name: string; how: string; vm?: string; domain?: string }[] = [];
        const infra: string[] = [];
        const self: string[] = [];
        const uncovered: { name: string; vm?: string; domain?: string; port?: number; category?: string }[] = [];
        for (const name of allServices) {
          const svc = topo.services[name];
          if (SELF_SERVICES.has(name)) {
            self.push(name);
          } else if (NATIVE_WRAPPED.has(name)) {
            covered.push({ name, how: "native-wrapper", vm: svc.vm, domain: svc.domain });
          } else if (PROXIED_MCPS.has(name)) {
            covered.push({ name, how: "proxied-mcp", vm: svc.vm, domain: svc.domain });
          } else if (INFRA_NO_API.has(name)) {
            infra.push(name);
          } else {
            uncovered.push({ name, vm: svc.vm, domain: svc.domain, port: svc.port, category: svc.category });
          }
        }
        const total = allServices.length;
        const coveredCount = covered.length + self.length;
        const pct = total > 0 ? Math.round((coveredCount / (total - infra.length)) * 100) : 0;
        const report = {
          summary: {
            total_services: total,
            covered: covered.length,
            proxied_mcps: covered.filter(c => c.how === "proxied-mcp").length,
            native_wrappers: covered.filter(c => c.how === "native-wrapper").length,
            self_hub: self.length,
            infra_no_api: infra.length,
            uncovered: uncovered.length,
            coverage_pct: `${pct}%`,
          },
          uncovered,
          covered,
          self,
          infra_no_api: infra,
        };
        return { content: [{ type: "text" as const, text: JSON.stringify(report, null, 2) }] };
      }

      case "proxy.api_call": {
        const baseUrl = registry.getBaseUrl(p.service);
        if (!baseUrl) {
          return { content: [{ type: "text" as const, text: `Service '${p.service}' not found` }], isError: true };
        }
        const svc = registry.get(p.service)!;
        if (svc.api.type === "no-api") {
          return { content: [{ type: "text" as const, text: `Service '${p.service}' has no API` }], isError: true };
        }
        const envToken = process.env[`${(p.service as string).toUpperCase()}_API_TOKEN`];
        const headers: Record<string, string> = {};
        if (envToken) headers["Authorization"] = `Bearer ${envToken}`;
        const result = rawHttpRequest(p.method, `${baseUrl}${p.path}`, p.body, 30_000,
          Object.keys(headers).length > 0 ? headers : undefined);
        return {
          content: [{ type: "text" as const, text: JSON.stringify({
            status: result.status,
            ok: result.ok,
            data: result.data,
            ...(result.error ? { error: result.error } : {}),
          }, null, 2) }],
        };
      }

      case "registry.services_list": {
        const services = registry.list().map((s) => ({
          name: s.name,
          displayName: s.displayName,
          description: s.description,
          vm: s.vm,
          apiType: s.api.type,
          endpointCount: s.api.endpointCount,
          hasSpec: !!s.api.specUrl,
        }));
        return { content: [{ type: "text" as const, text: JSON.stringify({ services, total: services.length }, null, 2) }] };
      }

      case "registry.services_info": {
        const svc = registry.get(p.service);
        if (svc) {
          return { content: [{ type: "text" as const, text: JSON.stringify({ source: "local", ...svc }, null, 2) }] };
        }
        const publicResult = searchPublicRegistry(p.service, 5);
        if (publicResult.servers.length > 0) {
          return {
            content: [{
              type: "text" as const,
              text: JSON.stringify({
                source: "public-registry",
                note: `'${p.service}' not found in local infrastructure. Found ${publicResult.total} match(es) in the public MCP registry (registry.modelcontextprotocol.io):`,
                servers: publicResult.servers,
              }, null, 2),
            }],
          };
        }
        return { content: [{ type: "text" as const, text: `Service '${p.service}' not found in local infrastructure or public MCP registry.` }], isError: true };
      }

      case "registry.services_spec": {
        const svc = registry.get(p.service);
        if (!svc) {
          return { content: [{ type: "text" as const, text: `Service '${p.service}' not found locally. Use registry-mcp_search to find public MCP servers.` }], isError: true };
        }
        if (!svc.api.specUrl) {
          return { content: [{ type: "text" as const, text: `Service '${p.service}' has no OpenAPI spec URL` }], isError: true };
        }
        const spec = await registry.fetchSpec(p.service);
        if (!spec) {
          return { content: [{ type: "text" as const, text: "Failed to fetch spec" }], isError: true };
        }
        return { content: [{ type: "text" as const, text: JSON.stringify(spec, null, 2) }] };
      }

      case "registry.mcp_search": {
        const result = searchPublicRegistry(p.query, p.limit ?? 10);
        if (result.servers.length === 0) {
          return { content: [{ type: "text" as const, text: `No MCP servers found for '${p.query}' in registry.modelcontextprotocol.io` }] };
        }
        const formatted = result.servers.map((s) => {
          const toolList = s.tools?.map((t: any) => `    - ${t.name}: ${t.description ?? ""}`).join("\n") ?? "    (tools not listed)";
          const source = s.source?.repo ? `github.com/${s.source.owner}/${s.source.repo}` : s.source?.url ?? "unknown";
          return `## ${s.name}\n${s.description}\n- **Version**: ${s.version ?? "latest"}\n- **Source**: ${source}\n- **Tools**:\n${toolList}`;
        });
        return {
          content: [{
            type: "text" as const,
            text: `# Public MCP Registry — "${p.query}" (${result.total} results)\n\n${formatted.join("\n\n---\n\n")}`,
          }],
        };
      }

      case "registry.mcp_get": {
        const server_info = getPublicServer(p.name, p.version ?? "latest");
        if (!server_info) {
          return { content: [{ type: "text" as const, text: `Server '${p.name}' not found in public registry` }], isError: true };
        }
        return { content: [{ type: "text" as const, text: JSON.stringify(server_info, null, 2) }] };
      }

      default:
        return { content: [{ type: "text" as const, text: `Unknown method: ${method}` }], isError: true };
    }
  });
}
