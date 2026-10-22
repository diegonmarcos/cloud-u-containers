// Guard: fleet naming + addressing rule (ticket #1100).
//  naming   : API containers end in -api, MCP servers in -mcp, names are valid host labels
//  mesh     : a container's mesh name (build.json dns, *.app) is "<name>.app"
//  no_api_host : nothing is served from the api.diegonmarcos.com host
//  public_host / public_subdomain : no per-app public subdomain (#1104): a container is public only at c3-pvt/{container}
//  protected: a route with wg_only:false is auth-protected unless its host is on the unprotected allowlist
//  pages    : github-pages hosts are on the unprotected allowlist
// _shared/fleet-addressing.json holds the allowlist (host -> reason) and a transitional
// list per rule. A listed entry that no longer violates FAILS (the lists only shrink);
// they must be empty when ticket #1100 phase P4 lands. Run: node test-fleet-addressing.mjs
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(process.cwd(), process.cwd().endsWith("_shared") ? ".." : ".");
const cfg = JSON.parse(readFileSync(join(root, "_shared/fleet-addressing.json"), "utf8"));
const DOM = "diegonmarcos.com";
const unprotected = new Set(Object.keys(cfg.unprotected_hosts));
const apiNames = new Set(cfg.api_containers || []);
// #1104 mesh transport: the canonical mesh address is http://<name>.app:<port>, dialled directly on the
// container's VM wg0 address. A container with a declared port needs an owned Hickory row for <name>.
const hk = JSON.parse(readFileSync(join(root, "infra-net_hickory-dns/build.json"), "utf8"));
const meshDirect = new Set((hk.dns?.records?.app ?? []).map((r) => r.name));
const found = {}; // rule -> Set(container)
const hit = (rule, n) => (found[rule] ??= new Set()).add(n);

const blocks = (o, acc = []) => {
  if (Array.isArray(o)) o.forEach((x) => blocks(x, acc));
  else if (o && typeof o === "object") {
    if (o.domain || o.parent_domain) acc.push(o);
    Object.values(o).forEach((x) => blocks(x, acc));
  }
  return acc;
};
const hostOf = (b) => String(b.parent_domain || b.domain).split(",")[0].trim();

for (const d of readdirSync(root, { withFileTypes: true })) {
  if (!d.isDirectory() || d.name === "z_archive" || d.name.startsWith(".")) continue;
  const f = join(root, d.name, "build.json");
  if (!existsSync(f)) continue;
  const j = JSON.parse(readFileSync(f, "utf8"));
  const n = j.name;
  const isMcp = /-mcp$/.test(n);
  const apiish = apiNames.has(n) || (!isMcp && (d.name.startsWith("infra-api_") || /(^|[-_])api($|[-_])/.test(n)));
  if (!/^[a-z0-9-]+$/.test(n) || (apiish && !n.endsWith("-api"))) hit("naming", n);
  if (typeof j.dns === "string" && j.dns.endsWith(".app") && j.dns !== `${n}.app`) hit("mesh", n);
  const port = j.ports?.app ?? j.containers?.app?.port;
  if (typeof j.dns === "string" && j.dns === `${n}.app` && Number.isInteger(port) && !meshDirect.has(n)) hit("mesh_direct", n);
  const ph = j.proxy?.primary?.public_host;
  if (ph !== undefined) hit("public_host", n); // never transitional (#1104): no per-app public subdomain, the public address is c3-pvt/{container}
  for (const b of blocks(j.proxy ?? {})) {
    const h = hostOf(b);
    if (h === `api.${DOM}`) hit("no_api_host", n);
    if (b.wg_only === false && !unprotected.has(h)) hit("public_subdomain", n); // #1104: a public per-app host (api.*, mcp.*, own subdomain)
    if (b.wg_only === false && !unprotected.has(h) && !["two_factor", "bearer"].includes(b.auth)) hit("protected", n);
  }
  for (const p of j.proxy?.github_pages_proxies ?? [])
    for (const h of p.domain.split(",").map((s) => s.trim())) if (!unprotected.has(h)) hit("pages", `${n}:${h}`); // explicit public Pages hosts only
}

let fail = 0;
// ── Tiers (ticket #1104): the rendered hub Caddyfile must carry the c3-pvt and c3-pub sites as declared ──
const siteOf = (text, host) => {
  const m = [...text.matchAll(/^ {2,4}([^\n{]+) \{$/gm)].find((x) => x[1].split(",").map((h) => h.trim()).includes(host) && !/^\s*(handle|route|header|tls|log|proxy|not|zone|bind)\b/.test(x[1]));
  if (!m) return null;
  let d = 0, i = m.index + m[0].length - 1;
  for (; i < text.length; i++) { d += (text[i] === "{") - (text[i] === "}"); if (d === 0) break; }
  return text.slice(m.index, i + 1);
};
const pathAllowed = (p, allow) => allow.some((a) => a.endsWith("/*") ? p === a || p.startsWith(a.slice(0, -1)) : p === a);
const tierProblems = (text) => {
  const out = [], T = cfg.tiers;
  if (!T) return out;
  const pvt = siteOf(text, T.pvt.host), pub = siteOf(text, T.pub.host);
  if (!pvt) out.push(`tiers: ${T.pvt.host} site missing from the rendered Caddyfile`);
  else {
    if (!/^ *import edge_auth( |$)/m.test(pvt)) out.push(`tiers: ${T.pvt.host} must import the edge_auth gate (cookie or bearer)`);
    if (/^ *import edge_auth_offmesh/m.test(pvt)) out.push(`tiers: ${T.pvt.host} must not use the off-mesh gate`);
    if (/^ *(respond|redir) /m.test(pvt.replace(/handle \{[^}]*\}/g, ""))) out.push(`tiers: ${T.pvt.host} has a site-level respond/redir outside a handle`);
    for (const m of pvt.matchAll(/handle_path (\/[^\s]*)/g)) if (!/^\/[a-z0-9_-]+\/\*$/.test(m[1])) out.push(`tiers: ${T.pvt.host} path ${m[1]} is not /{container}/*`);
  }
  if (!pub) out.push(`tiers: ${T.pub.host} site missing from the rendered Caddyfile`);
  else {
    if (/^ *import edge_auth/m.test(pub)) out.push(`tiers: ${T.pub.host} is an allowlist site and must not import a gate`);
    const seen = [...pub.matchAll(/^ *handle (\/[^\s]*) \{/gm)].map((m) => m[1]);
    for (const m of pub.matchAll(/^ *@\w+ path ([^\n]+)/gm)) seen.push(...m[1].trim().split(/\s+/));
    for (const q of seen) if (!pathAllowed(q, T.pub.allowlist)) out.push(`tiers: ${T.pub.host} serves ${q}, which is not on tiers.pub.allowlist`);
    if (/^ *handle_path /m.test(pub)) out.push(`tiers: ${T.pub.host} must not mount container paths`);
    if (!/^ *handle \{\n\s*error "Not Found" 404/m.test(pub)) out.push(`tiers: ${T.pub.host} must end in a 404 default`);
  }
  // Public HTML tier and wildcard (owner ruling 2026-10-22): apex + www are the only unauthenticated hosts,
  // and the *.diegonmarcos.com site may only redirect to the apex.
  const P = T.public;
  if (P) {
    for (const h of P.html_hosts) {
      const blk = siteOf(text, h);
      if (!blk) { out.push(`tiers: public HTML host ${h} has no site`); continue; }
      if (/^ *import edge_auth/m.test(blk)) out.push(`tiers: public HTML host ${h} must not carry the gate`);
    }
    for (const k of Object.keys(cfg.unprotected_hosts)) if (k.includes("*")) out.push(`tiers: unprotected_hosts lists a wildcard (${k}); there is no public wildcard route`);
    for (const m of text.matchAll(/^ {2,4}(\*\.diegonmarcos\.com[^\n{]*) \{$/gm)) {
      const blk = siteOf(text, m[1]);
      if (!blk) continue;
      if (/reverse_proxy|file_server|^ *respond |handle_path|rewrite /m.test(blk)) out.push(`tiers: wildcard site ${m[1]} proxies, serves or responds; a wildcard may only redirect to the apex`);
      if (!blk.includes(`redir ${P.wildcard_redirect_to} `)) out.push(`tiers: wildcard site ${m[1]} must redirect to ${P.wildcard_redirect_to}`);
      if (/^ *import edge_auth/m.test(blk)) out.push(`tiers: wildcard site ${m[1]} carries the gate; it is a no-route redirect`);
    }
  }
  for (const [h, to] of Object.entries(T.redirects ?? {})) {
    if (h.startsWith("_")) continue;
    const blk = siteOf(text, h);
    if (!blk) out.push(`tiers: retired host ${h} has no redirect site`);
    else if (!blk.includes(`redir ${to}{uri} 308`)) out.push(`tiers: retired host ${h} must redirect (308) to ${to}`);
  }
  return out;
};
const CF = join(root, "infra-sec_caddy/dist/configs/Caddyfile");
if (cfg.tiers && existsSync(CF)) {
  const text = readFileSync(CF, "utf8");
  const probs = tierProblems(text);
  // Mutation proof: each defect must be caught, or the guard above proves nothing.
  const pubHost = cfg.tiers.pub.host, pvtHost = cfg.tiers.pvt.host;
  const muts = {
    "extra path on pub": text.replace(`    ${pubHost} {`, `    ${pubHost} {\n      handle /admin {\n        respond "x"\n      }`),
    "gate on pub": text.replace(`    ${pubHost} {`, `    ${pubHost} {\n      import edge_auth`),
    "wildcard proxies": text.replace(/(\n {2,4}\*\.diegonmarcos\.com \{\n)/, "$1      reverse_proxy 10.0.0.9:1\n"),
    "wildcard to elsewhere": text.replace(/redir https:\/\/diegonmarcos\.com\/ 302/, "redir https://evil.example/ 302"),
    "no gate on pvt": text.replace(new RegExp(`(${pvtHost.replace(/\./g, "\\.")} \\{[\\s\\S]*?)import edge_auth [^\\n]*\\n`), "$1"),
  };
  for (const [name, t] of Object.entries(muts)) if (tierProblems(t).length === 0) probs.push(`tiers: mutation "${name}" was not caught; the guard is blind`);
  for (const pr of probs) { fail++; console.error(`FAIL ${pr}`); }
  console.log(`tiers: ${probs.length ? probs.length + " problem(s)" : "c3-pvt gated, c3-pub confined to its allowlist, 5 mutations caught"}`);
}

const bad = (m) => { fail++; console.error(`FAIL ${m}`); };
for (const rule of ["public_host", "naming", "mesh", "no_api_host", "mesh_direct", "public_subdomain", "protected", "pages"]) {
  const got = found[rule] ?? new Set(), listed = new Set(cfg.transitional[rule] ?? []);
  for (const x of got) if (!listed.has(x)) bad(`${rule}: ${x} violates the fleet addressing rule (tickets #1100, #1104); fix it, do not list it`);
  for (const x of listed) if (!got.has(x)) bad(`${rule}: ${x} is on the transitional list but no longer violates; remove it`);
  console.log(`${rule}: ${got.size} violation(s), all transitional`);
}
console.log(fail ? `${fail} failed` : "ok");
process.exit(fail ? 1 : 0);
