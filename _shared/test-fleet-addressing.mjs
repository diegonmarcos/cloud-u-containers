// Guard: fleet naming + addressing rule (ticket #1100).
//  naming   : API containers end in -api, MCP servers in -mcp, names are valid host labels
//  mesh     : a container's mesh name (build.json dns, *.app) is "<name>.app"
//  no_api_host : nothing is served from the api.diegonmarcos.com host
//  host     : a public host is "<name>.diegonmarcos.com"
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
  const ph = j.proxy?.primary?.public_host;
  if (ph !== undefined && ph !== `${n}.${DOM}`) hit("public_host", n); // never transitional: a declared own host must be the container-name host
  for (const b of blocks(j.proxy ?? {})) {
    const h = hostOf(b);
    if (h === `api.${DOM}`) hit("no_api_host", n);
    if (!unprotected.has(h) && h !== `${n}.${DOM}` && typeof j.proxy?.type !== "string") hit("host", n);
    if (b.wg_only === false && !unprotected.has(h) && !["two_factor", "bearer"].includes(b.auth)) hit("protected", n);
  }
  for (const p of j.proxy?.github_pages_proxies ?? [])
    for (const h of p.domain.split(",").map((s) => s.trim())) if (!unprotected.has(h)) hit("pages", `${n}:${h}`);
}

let fail = 0;
const bad = (m) => { fail++; console.error(`FAIL ${m}`); };
for (const rule of ["public_host", "naming", "mesh", "no_api_host", "host", "protected", "pages"]) {
  const got = found[rule] ?? new Set(), listed = new Set(cfg.transitional[rule] ?? []);
  for (const x of got) if (!listed.has(x)) bad(`${rule}: ${x} violates the fleet addressing rule (ticket #1100); fix it, do not list it`);
  for (const x of listed) if (!got.has(x)) bad(`${rule}: ${x} is on the transitional list but no longer violates; remove it`);
  console.log(`${rule}: ${got.size} violation(s), all transitional`);
}
console.log(fail ? `${fail} failed` : "ok");
process.exit(fail ? 1 : 0);
