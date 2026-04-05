// derive-cloud-data.ts — Derive ALL per-consumer JSON files from consolidated
//
// Input:  cloud-data/_cloud-data-consolidated.json
// Output: cloud-data/cloud-data-*.json (18 files)
//
// Run: tsx derive-cloud-data.ts

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs";
import { resolve, join } from "path";

// ═══════════════════════════════════════════════════════════════════════════
// Paths
// ═══════════════════════════════════════════════════════════════════════════

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT_DEFAULT = resolve(ENGINE_DIR, "../../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT_DEFAULT, "..");
const CLOUD_ROOT = process.env.GIT_BASE ? join(GIT_BASE, "cloud") : CLOUD_ROOT_DEFAULT;
const CLOUD_DATA_DIR = join(GIT_BASE, "cloud-data");          // standalone repo — read + write target
const INPUT_JSON = join(CLOUD_DATA_DIR, "_cloud-data-consolidated.json");

// ═══════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════

interface DerivedFile {
  name: string;
  data: unknown;
}

// ═══════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════

function now(): string {
  return new Date().toISOString();
}

/** Build ssh_alias → vm entry map */
function buildAliasToVm(vms: Record<string, any>): Record<string, { vmId: string; vm: any }> {
  const map: Record<string, { vmId: string; vm: any }> = {};
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.ssh_alias) map[vm.ssh_alias] = { vmId, vm };
  }
  return map;
}

/** Build vmId → ssh_alias map */
function buildVmIdToAlias(vms: Record<string, any>): Record<string, string> {
  const map: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(vms)) {
    if (vm.ssh_alias) map[vmId] = vm.ssh_alias;
  }
  return map;
}

// ═══════════════════════════════════════════════════════════════════════════
// Derivation functions
// ═══════════════════════════════════════════════════════════════════════════

function deriveDatabases(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  // ── DB type detection ──────────────────────────────────────────────────
  const DB_IMAGE_RE: [RegExp, string][] = [
    [/^(postgres|ghcr\.io\/.*postgres)/i, "postgres"],
    [/^(mariadb|mysql)/i, "mariadb"],
    [/^(redis|valkey)/i, "redis"],
    [/^(surrealdb|ghcr\.io\/.*surrealdb)/i, "surrealdb"],
    [/^(mongo)/i, "mongo"],
  ];

  function inferDbType(ct: any): string | null {
    if (ct.db_path) return "sqlite";
    const img = ct.image ?? "";
    for (const [re, type] of DB_IMAGE_RE) {
      if (re.test(img)) return type;
    }
    if (ct.dump_cmd) return "custom";
    return null;
  }

  function isDbContainer(ct: any): boolean {
    return !!(ct.db_user || ct.db_name || ct.db_path || ct.dump_cmd || inferDbType(ct));
  }

  // ── Scan all services ──────────────────────────────────────────────────
  const databases: any[] = [];
  const byType: Record<string, any[]> = {};
  const byVm: Record<string, { wg_ip: string; user: string; databases: any[] }> = {};
  const summary = { postgres: 0, mariadb: 0, redis: 0, sqlite: 0, surrealdb: 0, custom: 0, mongo: 0 };

  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    const vmAlias = vmIdToAlias[svc.vm] ?? svc.vm;
    const vm = vms[svc.vm];
    const enabled = svc.enabled !== false;

    if (!svc.containers) continue;

    for (const [ctKey, ct] of Object.entries(svc.containers) as [string, any][]) {
      if (!isDbContainer(ct)) continue;

      const type = inferDbType(ct) ?? "custom";
      const port = ct.port ?? svc.declared_ports?.[ctKey] ?? null;
      const dns = ct.dns ?? null;

      const entry: any = {
        service: svcName,
        container: ct.container_name,
        container_key: ctKey,
        type,
        enabled,
        vm: svc.vm,
        vm_alias: vmAlias,
        wg_ip: vm?.wg_ip ?? null,
        image: ct.image ?? null,
        port,
        dns,
        ...(ct.db_user ? { user: ct.db_user } : {}),
        ...(ct.db_name ? { db: ct.db_name } : {}),
        ...(ct.db_path ? { path: ct.db_path } : {}),
        ...(ct.dump_cmd ? { dump_cmd: ct.dump_cmd } : {}),
        ...(ct.healthcheck ? { healthcheck: ct.healthcheck } : {}),
        volumes: ct.volumes ?? [],
        resources: ct.resources ?? null,
        backup: svc.backup?.enabled ?? false,
      };

      // Connection string hint
      if (type === "postgres" && ct.db_user && ct.db_name && vm?.wg_ip && port) {
        entry.connection = `postgresql://${ct.db_user}@${vm.wg_ip}:${port}/${ct.db_name}`;
      } else if (type === "mariadb" && ct.db_user && ct.db_name && vm?.wg_ip && port) {
        entry.connection = `mysql://${ct.db_user}@${vm.wg_ip}:${port}/${ct.db_name}`;
      } else if (type === "redis" && vm?.wg_ip && port) {
        entry.connection = `redis://${vm.wg_ip}:${port}`;
      }

      databases.push(entry);

      // Group by type
      if (!byType[type]) byType[type] = [];
      byType[type].push(entry);

      // Count
      if (type in summary) (summary as any)[type]++;

      // Group by VM
      if (!byVm[vmAlias]) {
        byVm[vmAlias] = {
          wg_ip: vm?.wg_ip ?? "",
          user: vm?.user ?? "ubuntu",
          databases: [],
        };
      }
      byVm[vmAlias].databases.push(entry);
    }
  }

  // ── VM-level system databases ──────────────────────────────────────────
  const vmDatabases: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    const alias = vm.ssh_alias;
    if (!alias) continue;

    vmDatabases[alias] = {
      vm_id: vmId,
      wg_ip: vm.wg_ip ?? null,
      system_dbs: [
        {
          name: "journald",
          type: "binary",
          path: "/var/log/journal/",
          description: "systemd journal logs (binary)",
          queryable: true,
          tool: "journalctl",
        },
        {
          name: "systemd-state",
          type: "binary",
          path: "/var/lib/systemd/",
          description: "systemd persistent state (timers, random-seed)",
          queryable: false,
        },
      ],
    };
  }

  return {
    name: "cloud-data-databases.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/databases",
      total: databases.length,
      summary,
      databases,
      by_type: byType,
      by_vm: byVm,
      vm_system_dbs: vmDatabases,
    },
  };
}

function deriveDnsServices(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;

  // All *.app zones resolve to Caddy (reverse proxy handles port routing)
  // Find Caddy's WG IP from the caddy service entry
  const caddySvc = services["caddy"];
  const caddyVm = caddySvc ? vms[caddySvc.vm] : null;
  const caddyIp = caddyVm?.wg_ip ?? "10.0.0.1";

  // Build service entries: key = dns name without .app suffix, ip = Caddy's WG IP
  const svcEntries: Record<string, { ip: string; desc: string }> = {};

  for (const [svcName, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm?.wg_ip) continue;

    // Add entries for each container with a dns field
    for (const container of Object.values(svc.containers ?? {})) {
      const ct = container as any;
      if (ct.dns) {
        const key = ct.dns.endsWith(".app") ? ct.dns.slice(0, -4) : ct.dns;
        svcEntries[key] = { ip: caddyIp, desc: svc.description ?? "" };
      }
    }

    // Also add top-level dns if present and no container dns matched
    if (svc.dns && !Object.values(svc.containers ?? {}).some((ct: any) => ct.dns)) {
      const key = svc.dns.endsWith(".app") ? svc.dns.slice(0, -4) : svc.dns;
      svcEntries[key] = { ip: caddyIp, desc: svc.description ?? "" };
    }
  }

  // Build VMs map: last octet → ssh_alias
  const vmMap: Record<string, string> = {};
  for (const vm of Object.values(vms)) {
    if (vm.wg_ip && vm.ssh_alias) {
      const lastOctet = vm.wg_ip.split(".").pop()!;
      vmMap[lastOctet] = vm.ssh_alias;
    }
  }

  return {
    name: "cloud-data-dns-services.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/dns-services",
      suffix: "app",
      caddy_ip: caddyIp,
      services: svcEntries,
      vms: vmMap,
    },
  };
}

function deriveCaddyRoutes(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const flatRoutes: any[] = c.configs?.caddy?.routes ?? [];

  // Build dns→wg_ip map to resolve any lingering name.app:port → WG_IP:port
  const dnsToIp: Record<string, string> = {};
  for (const [, svc] of Object.entries(services)) {
    const vm = vms[svc.vm];
    if (!vm?.wg_ip || !svc.dns) continue;
    dnsToIp[svc.dns] = vm.wg_ip;
    for (const ct of Object.values(svc.containers ?? {})) {
      const c = ct as any;
      if (c.dns) dnsToIp[c.dns] = vm.wg_ip;
    }
  }
  const resolveUpstream = (upstream: string | undefined): string | undefined => {
    if (!upstream) return upstream;
    const m = upstream.match(/^([a-z0-9-]+\.app):(\d+)$/);
    if (m && dnsToIp[m[1]]) return `${dnsToIp[m[1]]}:${m[2]}`;
    return upstream;
  };

  // ── L4 routes: derive from gcp-proxy public_ports for mail passthrough ──
  const l4Routes: any[] = [];
  const l4Map: Record<number, string> = {
    993: "IMAPS -- TLS passthrough to stalwart",
    465: "SMTPS -- TLS passthrough to stalwart",
    587: "SMTP Submission -- TLS passthrough to stalwart",
  };
  // Find oci-mail's WG IP for upstream (Caddy L4 runs inside WG mesh)
  let ociMailIp = "";
  for (const vm of Object.values(vms) as any[]) {
    if (vm.ssh_alias === "oci-mail") { ociMailIp = vm.wg_ip ?? vm.ip; break; }
  }
  for (const vm of Object.values(vms) as any[]) {
    if (vm.ssh_alias !== "gcp-proxy") continue;
    for (const pp of vm.public_ports ?? []) {
      if (l4Map[pp.port]) {
        l4Routes.push({
          port: pp.port,
          upstream: `${ociMailIp}:${pp.port}`,
          comment: l4Map[pp.port],
        });
      }
    }
  }

  // ── Domain routes: services with domain-level proxy ──
  const routes: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy?.domain || proxy.type === "path" || proxy.type === "special" || proxy.streaming || proxy.base_path) continue;
    const route: any = {
      domain: proxy.domain,
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
      ...(proxy.landing_page ? { landing_page: proxy.landing_page } : {}),
      ...(proxy.tls_skip_verify ? { tls_skip_verify: true } : {}),
      ...(proxy.auth === "none" ? { auth: "none" } : {}),
      comment: svc.description,
    };
    routes.push(route);
  }
  // introspect-proxy is caddy-internal (no external route — consumed by Caddy's forward_auth)

  // ── Path routes: group by parent_domain ──
  const pathGroups: Record<string, { paths: any[]; comment: string; fallback?: string; landing_page?: string }> = {};

  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy || proxy.streaming) continue;
    // Include explicit path type OR services with base_path (implicit path route)
    const isPathRoute = proxy.type === "path" || (proxy.base_path && proxy.domain);
    if (!isPathRoute) continue;
    const pd = proxy.parent_domain ?? proxy.domain;
    if (!pd) continue;
    if (!pathGroups[pd]) pathGroups[pd] = { paths: [], comment: "" };
    pathGroups[pd].paths.push({
      base_path: proxy.base_path,
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
      ...(proxy.public_paths ? { public_paths: proxy.public_paths } : {}),
      comment: svc.description,
    });
  }

  // Also scan flat routes for path-based entries that services don't have
  // (e.g., crawlee dashboard on app hub, windmill, gitea, grafana on app hub,
  //  api/dash redirect, etc.)
  for (const fr of flatRoutes) {
    const domain: string = fr.domain ?? "";
    if (!domain.includes("/")) continue; // Only path-based routes
    const slashIdx = domain.indexOf("/");
    const parentDomain = domain.substring(0, slashIdx);
    const basePath = domain.substring(slashIdx);
    if (!pathGroups[parentDomain]) pathGroups[parentDomain] = { paths: [], comment: "" };
    // Skip if already have this base_path from services
    if (pathGroups[parentDomain].paths.some((p: any) => p.base_path === basePath)) continue;
    const pathEntry: any = {
      base_path: basePath,
      ...(fr.upstream && fr.upstream !== "static" ? { upstream: resolveUpstream(fr.upstream) } : {}),
      ...(fr.public_paths?.length > 0 ? { public_paths: fr.public_paths } : {}),
      ...(fr.upstream === "diegonmarcos.github.io" ? { type: "github_pages", github_path: basePath.replace(/^\//, ""), redirect_bare: true } : {}),
      comment: fr.comment ?? "",
    };
    pathGroups[parentDomain].paths.push(pathEntry);
  }

  // Set group metadata
  const groupMeta: Record<string, { comment: string; fallback?: string; landing_page?: string }> = {
    "app.diegonmarcos.com": { comment: "App hub -- path-based routing", fallback: 'respond "Not Found" 404' },
    "api.diegonmarcos.com": { comment: "API hub -- path-based routing to backend APIs", landing_page: "api" },
    "cloud.diegonmarcos.com": { comment: "Cloud dashboard + spec viewer", landing_page: "cloud" },
  };
  for (const [pd, meta] of Object.entries(groupMeta)) {
    if (pathGroups[pd]) {
      pathGroups[pd].comment = meta.comment;
      if (meta.fallback) pathGroups[pd].fallback = meta.fallback;
      if (meta.landing_page) pathGroups[pd].landing_page = meta.landing_page;
    }
  }

  const pathRoutes = Object.entries(pathGroups).map(([domain, group]) => ({
    parent_domain: domain,
    paths: group.paths,
    comment: group.comment,
    ...(group.fallback ? { fallback: group.fallback } : {}),
    ...(group.landing_page ? { landing_page: group.landing_page } : {}),
  }));

  // ── GitHub Pages proxies: from caddy build.json proxy.github_pages_proxies ──
  const caddyBuildJsonPath = join(CLOUD_ROOT, "a_solutions/bb-sec_caddy/src/build.json");
  const caddyBuildJson = existsSync(caddyBuildJsonPath)
    ? JSON.parse(readFileSync(caddyBuildJsonPath, "utf-8"))
    : {};
  const githubPagesProxies: any[] = (caddyBuildJson.proxy?.github_pages_proxies ?? []).map(
    (entry: any) => ({
      domain: entry.domain,
      github_path: entry.github_path,
      ...(entry.wkd ? { wkd: true } : {}),
      ...(entry.comment ? { comment: entry.comment } : {}),
    }),
  );

  // ── MCP routes: streaming services ──
  const mcpEndpoints: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    const proxy = svc.proxy?.primary;
    if (!proxy?.streaming || !proxy.parent_domain) continue;
    mcpEndpoints.push({
      base_path: proxy.base_path,
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
    });
  }
  const mcpRoutes = mcpEndpoints.length > 0 ? [{
    parent_domain: "mcp.diegonmarcos.com",
    endpoints: mcpEndpoints,
    comment: "MCP -- Streamable HTTP endpoints for Claude Code MCP clients",
    fallback_message: "MCP Hub -- use " + mcpEndpoints.map(e => `${e.base_path}/mcp`).join(", "),
  }] : [];

  // ── Special routes: ntfy (3-tier auth), analytics (matomo+umami), proxy dashboard ──
  const special: Record<string, any> = {};

  // ntfy
  const ntfySvc = services["ntfy"];
  if (ntfySvc) {
    special.ntfy = {
      domain: ntfySvc.domain ?? ntfySvc.proxy?.primary?.domain,
      upstream: ntfySvc.upstream,
      comment: "ntfy notifications -- 3-tier auth: JWT bearer, tk_ bearer, cookie",
    };
  }

  // analytics (matomo + umami)
  const matomoSvc = services["matomo"];
  const umamiSvc = services["umami"];
  if (matomoSvc) {
    special.analytics = {
      domain: matomoSvc.domain ?? matomoSvc.proxy?.primary?.domain,
      comment: "Matomo (public tracking + protected admin) + Umami (path-based)",
      matomo_upstream: matomoSvc.upstream,
      ...(umamiSvc?.upstream ? { umami_upstream: umamiSvc.upstream } : {}),
      public_tracking_paths: ["/matomo.js", "/matomo.php", "/piwik.js", "/piwik.php", "/collect.php", "/api.php", "/track.php", "/js/*"],
      ...(umamiSvc ? { umami_public_paths: ["/umami/script.js", "/umami/api/send"] } : {}),
    };
  }

  // proxy dashboard
  const caddySvc = services["caddy"];
  if (caddySvc) {
    special.proxy_dashboard = {
      domain: caddySvc.domain ?? "proxy.diegonmarcos.com",
      comment: "Infrastructure dashboard (static HTML)",
    };
  }

  // Exclude domains handled by special routes from regular routes/path_routes
  const specialDomains = new Set(Object.values(special).map((s: any) => s.domain).filter(Boolean));
  const filteredRoutes = routes.filter((r: any) => !specialDomains.has(r.domain));
  const filteredPathRoutes = pathRoutes.filter((r: any) => !specialDomains.has(r.parent_domain));

  // Deduplicate subdomain routes by domain (keep first occurrence)
  const seenDomains = new Set<string>();
  const dedupedRoutes = filteredRoutes.filter((r: any) => {
    if (seenDomains.has(r.domain)) return false;
    seenDomains.add(r.domain);
    return true;
  });

  // ── Internal routes: all services with upstream + dns → Caddy HTTP:80 listener ──
  const internalRoutes: any[] = [];
  for (const [, svc] of Object.entries(services)) {
    if (!svc.upstream || !svc.dns) continue;
    internalRoutes.push({
      service: svc.dns,
      upstream: svc.upstream,
    });
  }
  // VM dashboards: from HM build.json dashboard field → <alias>.app internal routes
  const hmVms = c._home_manager?.vms ?? {};
  for (const [, vm] of Object.entries(hmVms) as [string, any][]) {
    if (vm.dashboard?.dns && vm.wg_ip) {
      internalRoutes.push({
        service: vm.dashboard.dns,
        upstream: `${vm.wg_ip}:${vm.dashboard.port ?? 7681}`,
      });
    }
  }

  // ── Auth upstreams: Caddy forward_auth targets (from cloud-data, not hardcoded) ──
  const authUpstreams: Record<string, string> = {};
  const authSvc = services["authelia"];
  if (authSvc?.upstream) authUpstreams.authelia = authSvc.upstream;
  const introspectSvc = services["introspect-proxy"];
  if (introspectSvc?.upstream) authUpstreams.introspect_proxy = introspectSvc.upstream;

  return {
    name: "cloud-data-caddy-routes.json",
    data: {
      _meta: {
        description: "Caddy route definitions -- consumed by flake.nix to generate Caddyfile",
        format_version: 2,
      },
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/caddy-routes",
      l4_routes: l4Routes,
      routes: dedupedRoutes,
      path_routes: filteredPathRoutes,
      github_pages_proxies: githubPagesProxies,
      mcp_routes: mcpRoutes,
      special,
      internal_routes: internalRoutes,
      auth_upstreams: authUpstreams,
    },
  };
}

function deriveAutheliaAcl(c: any): DerivedFile {
  const acl: any[] = c.configs?.authelia?.acl ?? [];

  // Enrich each rule with a `service` field if missing (backward compat)
  const rules = acl.map(rule => ({
    ...rule,
    service: rule.service ?? "_default",
  }));

  return {
    name: "cloud-data-authelia-acl.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/authelia-acl",
      rules,
    },
  };
}

function deriveHomeManager(c: any): DerivedFile {
  const hmData = c._home_manager ?? {};
  const vms = hmData.vms ?? {};
  const sshConfig = hmData.ssh_config ?? [];

  // Enrich wireguard peers with wg_public_key from HM build.json + VM entries
  const wg = { ...(c.native?.wireguard ?? {}) };

  // Read wg_public_key from each VM's HM build.json (authoritative source for per-VM keys)
  const hmKeysByAlias = new Map<string, string>();
  const HM_DIR = join(CLOUD_ROOT, "b_infra", "home-manager");
  for (const vmAlias of ["gcp-proxy", "oci-mail", "oci-analytics", "oci-apps", "gcp-t4"]) {
    try {
      const buildJsonPath = join(HM_DIR, vmAlias, "build.json");
      if (existsSync(buildJsonPath)) {
        const buildJson = JSON.parse(readFileSync(buildJsonPath, "utf-8"));
        if (buildJson.wg_public_key) hmKeysByAlias.set(vmAlias, buildJson.wg_public_key);
      }
    } catch { /* skip unreadable */ }
  }

  // Fallback: preserve existing keys from cloud-data-home-manager.json
  // (critical when running on VMs where HM build.json isn't accessible)
  const existingHmPath = join(CLOUD_DATA_DIR, "cloud-data-home-manager.json");
  const existingKeysByName = new Map<string, string>();
  if (existsSync(existingHmPath)) {
    try {
      const existing = JSON.parse(readFileSync(existingHmPath, "utf-8"));
      for (const peer of (existing.wireguard?.peers ?? [])) {
        if (peer.name && peer.wg_public_key) existingKeysByName.set(peer.name, peer.wg_public_key);
      }
    } catch { /* skip */ }
  }

  if (Array.isArray(wg.peers) && c.vms) {
    const vmsByAlias = new Map<string, any>();
    for (const vm of Object.values(c.vms) as any[]) {
      if (vm.ssh_alias) vmsByAlias.set(vm.ssh_alias, vm);
    }
    wg.peers = wg.peers.map((peer: any) => {
      const vm = vmsByAlias.get(peer.name);
      const enriched: any = { ...peer };
      // Priority: HM build.json > config.json VM entry > existing cloud-data > peer value
      const hmKey = hmKeysByAlias.get(peer.name);
      const existingKey = existingKeysByName.get(peer.name);
      if (hmKey) enriched.wg_public_key = hmKey;
      else if (vm?.wg_public_key && !peer.wg_public_key) enriched.wg_public_key = vm.wg_public_key;
      else if (existingKey && !enriched.wg_public_key) enriched.wg_public_key = existingKey;
      if (vm?.wg_port && !peer.wg_port) enriched.wg_port = vm.wg_port;
      if (vm?.ip && !peer.public_ip) enriched.public_ip = vm.ip;
      if (!enriched.public_ip && peer.endpoint?.includes(":")) {
        enriched.public_ip = peer.endpoint.split(":")[0];
      }
      return enriched;
    });
  }

  // Validate: warn if any peer still has null wg_public_key
  if (Array.isArray(wg.peers)) {
    for (const peer of wg.peers) {
      if (!peer.wg_public_key) {
        console.warn(`WARNING: wireguard peer "${peer.name}" has no wg_public_key — WG mesh will be broken for this peer`);
      }
    }
  }
  // Validate clients too
  if (wg.clients) {
    for (const [name, client] of Object.entries(wg.clients) as [string, any][]) {
      if (!client.wg_public_key) {
        console.warn(`WARNING: wireguard client "${name}" has no wg_public_key — WG mesh will be broken for this client`);
      }
    }
  }

  return {
    name: "cloud-data-home-manager.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/home-manager",
      owner: c.owner ?? {},
      home_manager: c.home_manager ?? { state_version: "24.11" },
      vms,
      wireguard: wg,
      dns: c.native?.dns ?? {},
      docker: c.native?.docker ?? {},
      monitoring: c.native?.monitoring ?? {},
      ssh_config: sshConfig,
    },
  };
}

function deriveGhaConfig(c: any): DerivedFile {
  const ghaData = c._gha ?? {};
  // Enrich GHA VMs with WG IPs from main VM data
  const vms: Record<string, any> = {};
  for (const [vmAlias, ghaVm] of Object.entries(ghaData.vms ?? {}) as [string, any][]) {
    const mainVm = Object.values(c.vms ?? {}).find((v: any) => v.ssh_alias === vmAlias) as any;
    // Hub (gcp-proxy) uses public IP for GHA SSH (Docker can't route to WG hub IP)
    const isHub = mainVm?.wg_role === "hub";
    const enriched = { ...ghaVm, wg_ip: mainVm?.wg_ip ?? null };
    if (isHub && mainVm?.ip) {
      enriched.host = mainVm.ip;
      delete enriched.wg_ip;
    }
    vms[vmAlias] = enriched;
  }

  return {
    name: "cloud-data-gha-config.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/gha-config",
      vms,
      services: ghaData.services ?? {},
    },
  };
}

function deriveWireguardPeers(c: any): DerivedFile {
  const wg = c.native?.wireguard ?? {};
  const vms = c.vms as Record<string, any>;

  // Build mesh_peers from peers array enriched with VM data
  const meshPeers: any[] = [];
  for (const peer of (wg.peers ?? [])) {
    // Find VM by ssh_alias
    let vmUser = "ubuntu";
    let vmId = "";
    for (const [id, vm] of Object.entries(vms) as [string, any][]) {
      if (vm.ssh_alias === peer.name) {
        vmUser = vm.user;
        vmId = id;
        break;
      }
    }
    meshPeers.push({
      vm_id: vmId,
      name: peer.name,
      wg_ip: peer.wg_ip,
      public_ip: peer.endpoint?.replace(/:.*$/, "") ?? peer.public_ip ?? "",
      user: vmUser,
    });
  }

  // Add client peers (Surface, Termux, etc.) from wg.clients
  for (const [name, client] of Object.entries(wg.clients ?? {}) as [string, any][]) {
    meshPeers.push({
      vm_id: "",
      name,
      wg_ip: client.wg_ip,
      public_ip: "dynamic",
      user: "",
      role: client.role || "client",
    });
  }

  // Build peers list as vm_ids
  const peerVmIds = meshPeers
    .filter(p => p.wg_ip !== wg.peers?.find((wp: any) => wp.role === "hub")?.wg_ip)
    .map(p => p.vm_id)
    .filter(Boolean);

  return {
    name: "cloud-data-wireguard-peers.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/wireguard-peers",
      hub: wg.hub ?? null,
      peers: peerVmIds,
      mesh_peers: meshPeers,
    },
  };
}

function deriveFirewallRules(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  // Per-VM ingress arrays (currently empty as rules come from terraform)
  const vmFirewalls: Record<string, { ingress: any[] }> = {};
  for (const [vmId, vm] of Object.entries(vms)) {
    const alias = vm.ssh_alias;
    if (alias) {
      vmFirewalls[alias] = { ingress: [] };
    }
  }

  return {
    name: "cloud-data-firewall-rules.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/firewall-rules",
      vms: vmFirewalls,
    },
  };
}

function deriveMonitoringTargets(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;

  const endpointChecks: any[] = [];
  const dnsChecks: any[] = [];
  const tlsChecks: any[] = [];

  for (const [svcName, svc] of Object.entries(services)) {
    const mon = svc.monitoring;
    if (!mon) continue;
    if (mon.endpoint_check && svc.domain) {
      endpointChecks.push({
        service: svcName,
        url: `https://${svc.domain}${svc.health?.path ?? "/"}`,
      });
    }
    if (mon.dns_check && svc.domain) {
      dnsChecks.push({ service: svcName, domain: svc.domain });
    }
    if (mon.tls_check && svc.domain) {
      tlsChecks.push({ service: svcName, domain: svc.domain });
    }
  }

  const vmList = Object.values(vms)
    .filter((vm: any) => vm.wg_ip && vm.ssh_alias)
    .map((vm: any) => ({
      ip: vm.wg_ip,
      name: vm.ssh_alias,
      user: vm.user,
    }));

  return {
    name: "cloud-data-monitoring-targets.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/monitoring-targets",
      endpoint_checks: endpointChecks,
      dns_checks: dnsChecks,
      tls_checks: tlsChecks,
      vms: vmList,
    },
  };
}

function deriveBackupTargets(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;

  // Build VM alias lookup
  const vmIdToAlias: Record<string, string> = {};
  const vmById: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    if (vm.ssh_alias) vmIdToAlias[vmId] = vm.ssh_alias;
    vmById[vmId] = vm;
  }

  const targets: any[] = [];
  const byVm: Record<string, { wg_ip: string; user: string; databases: any[]; volumes: string[] }> = {};

  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    if (!svc.backup?.enabled) continue;

    const vmAlias = vmIdToAlias[svc.vm] ?? svc.vm;
    const vm = vmById[svc.vm];

    // Scan containers for DB metadata
    const databases: any[] = [];
    if (svc.containers) {
      for (const [ctKey, ct] of Object.entries(svc.containers) as [string, any][]) {
        const hasDbFields = ct.db_user || ct.db_name || ct.db_path || ct.dump_cmd;
        const isDbImage = /^(postgres|mariadb|mysql):/.test(ct.image ?? "");

        if (!hasDbFields && !isDbImage) continue;

        // Infer dump type from image
        let type = "custom";
        if (ct.db_path) type = "sqlite";
        else if (ct.dump_cmd) type = "custom";
        else if (/^postgres:/.test(ct.image ?? "")) type = "postgres";
        else if (/^mariadb:/.test(ct.image ?? "")) type = "mariadb";
        else if (/^mysql:/.test(ct.image ?? "")) type = "mariadb";

        databases.push({
          service: svcName,
          container: ct.container_name,
          container_key: ctKey,
          type,
          ...(ct.db_user ? { user: ct.db_user } : {}),
          ...(ct.db_name ? { db: ct.db_name } : {}),
          ...(ct.db_path ? { path: ct.db_path } : {}),
          ...(ct.dump_cmd ? { dump_cmd: ct.dump_cmd } : {}),
        });
      }
    }

    targets.push({
      service: svcName,
      vm: svc.vm,
      vm_alias: vmAlias,
      volumes: svc.backup.volumes ?? [],
      databases,
    });

    // Group by VM
    if (!byVm[vmAlias]) {
      byVm[vmAlias] = {
        wg_ip: vm?.wg_ip ?? "",
        user: vm?.user ?? "ubuntu",
        databases: [],
        volumes: [],
      };
    }
    byVm[vmAlias].databases.push(...databases);
    byVm[vmAlias].volumes.push(...(svc.backup.volumes ?? []));
  }

  return {
    name: "cloud-data-backup-targets.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/backup-targets",
      targets,
      by_vm: byVm,
    },
  };
}

function deriveContainerResources(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  const svcResources: Record<string, any> = {};
  for (const [svcName, svc] of Object.entries(services)) {
    const alias = vmIdToAlias[svc.vm] ?? svc.vm;
    const vm = vms[svc.vm];
    const containerNames = svc.container_names ?? [];

    // Check if any container has resource limits
    let resources: any = null;
    for (const ct of Object.values(svc.containers ?? {})) {
      if ((ct as any).resources) {
        resources = (ct as any).resources;
        break;
      }
    }

    svcResources[svcName] = {
      vm: alias,
      vm_ram_gb: vm?.specs?.ram_gb ?? null,
      vm_cpu: vm?.specs?.cpu ?? null,
      containers: containerNames,
      resources,
    };
  }

  return {
    name: "cloud-data-container-resources.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/container-resources",
      services: svcResources,
    },
  };
}

function deriveLogRouting(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  const vmLogs: Record<string, any[]> = {};
  for (const [svcName, svc] of Object.entries(services)) {
    const alias = vmIdToAlias[svc.vm] ?? svc.vm;
    if (!vmLogs[alias]) vmLogs[alias] = [];

    for (const ct of Object.values(svc.containers ?? {})) {
      const ctObj = ct as any;
      vmLogs[alias].push({
        container: ctObj.container_name,
        service: svcName,
        log_level: "info", // Default, can be overridden via container spec
      });
    }
  }

  return {
    name: "cloud-data-log-routing.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/log-routing",
      vms: vmLogs,
    },
  };
}

function deriveCloudflareDns(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const domain = c.owner?.domain ?? "diegonmarcos.com";

  // Derive DNS records from services with domains
  const records: any[] = [];
  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.domain && svc.domain !== "\u2014" && !svc.domain.endsWith(".internal")) {
      records.push({
        name: svc.domain,
        type: "CNAME",
        content: domain,
        proxied: true,
        service: svcName,
      });
    }
  }

  // Also check dns.cloudflare from consolidated if present
  if (c.dns?.cloudflare?.length > 0) {
    // Use pre-parsed cloudflare records
    return {
      name: "cloud-data-cloudflare-dns.json",
      data: {
        _generated: now(),
        _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/cloudflare-dns",
        zone: domain,
        records: c.dns.cloudflare,
      },
    };
  }

  return {
    name: "cloud-data-cloudflare-dns.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/cloudflare-dns",
      zone: domain,
      records,
    },
  };
}

function deriveMatomoSites(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const sites: any[] = [];

  for (const [svcName, svc] of Object.entries(services)) {
    if (svc.domain && svc.domain !== "\u2014") {
      sites.push({
        name: svc.description ?? svcName,
        url: `https://${svc.domain}`,
        service: svcName,
      });
    }
  }

  return {
    name: "cloud-data-matomo-sites.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/matomo-sites",
      sites,
    },
  };
}

function deriveNtfyAcl(c: any): DerivedFile {
  const ntfyConfig = c.configs?.ntfy;
  const topicList: any[] = ntfyConfig?.topics ?? [];

  // Build topics object keyed by name, grouped by category
  const topics: Record<string, any> = {};
  const categories: Record<string, string[]> = {};

  for (const t of topicList) {
    topics[t.name] = {
      category: t.category,
      desc: t.desc,
      publishers: t.publishers,
    };
    const cat = t.category;
    if (!categories[cat]) categories[cat] = [];
    categories[cat].push(t.name);
  }

  return {
    name: "cloud-data-ntfy-acl.json",
    data: {
      _generated: now(),
      _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/ntfy-acl",
      base_url: `https://${c.services?.ntfy?.dns?.domain ?? "rss.diegonmarcos.com"}`,
      auth_default_access: ntfyConfig?.auth_default_access ?? "read-write",
      users: ntfyConfig?.users ?? [],
      all_topics: topicList.map((t: any) => t.name).join(","),
      categories,
      topics,
    },
  };
}

// Per-VM container manifests for docker-pull-up.sh
// Produces one cloud-data-containers-{alias}.json per VM
function deriveVmContainerManifests(c: any): DerivedFile[] {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;
  const gha = c._gha ?? {};
  const ghaServices = gha.services ?? {};
  const vmIdToAlias = buildVmIdToAlias(vms);

  const files: DerivedFile[] = [];

  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    const alias = vm.ssh_alias;
    if (!alias) continue;

    const vmServices: any[] = [];
    for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
      if (svc.vm !== vmId) continue;

      // Collect all images from containers
      const images: string[] = [];
      for (const ct of Object.values(svc.containers ?? {})) {
        const img = (ct as any).image;
        if (img && img !== "" && !img.endsWith(":local")) {
          images.push(img);
        }
      }

      // Get has_docker from GHA config
      const ghaEntry = ghaServices[svcName] ?? {};
      const hasDockerBuild = ghaEntry.has_docker ?? false;
      const dir = ghaEntry.dir ?? svc.folder ?? svcName;

      vmServices.push({
        name: svcName,
        dir,
        compose_path: `/opt/containers/${svcName}`,
        images,
        has_docker_build: hasDockerBuild,
      });
    }

    if (vmServices.length === 0) continue;

    files.push({
      name: `cloud-data-containers-${alias}.json`,
      data: {
        _generated: now(),
        _source: "_cloud-data-consolidated.json via derive-cloud-data.ts/vm-container-manifests",
        vm: alias,
        vm_id: vmId,
        services: vmServices,
      },
    });
  }

  return files;
}

function deriveTopology(c: any): DerivedFile {
  // Backward compat: produce the old topology format from consolidated data
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;
  const vmIdToAlias = buildVmIdToAlias(vms);

  // Build old-style VM entries (keyed by vmId)
  const oldVms: Record<string, any> = {};
  for (const [vmId, vm] of Object.entries(vms) as [string, any][]) {
    // Build containers list from services assigned to this VM
    const vmContainers: string[] = [];
    const vmPorts: string[] = [];
    const vmNetworks: string[] = [];
    for (const [, svc] of Object.entries(services) as [string, any][]) {
      if (svc.vm !== vmId) continue;
      vmContainers.push(...(svc.container_names ?? []));
      vmPorts.push(...(svc.compose?.ports ?? []));
      vmNetworks.push(...(svc.compose?.networks ?? []));
    }
    // Deduplicate networks
    const uniqueNetworks = [...new Set(vmNetworks)];

    oldVms[vmId] = {
      ip: vm.ip,
      wg_ip: vm.wg_ip,
      user: vm.user,
      method: vm.method,
      ssh_alias: vm.ssh_alias,
      ...(vm.gcloud_instance ? { gcloud_instance: vm.gcloud_instance, gcloud_zone: vm.gcloud_zone } : {}),
      ...(vm.instance_id ? { instance_id: vm.instance_id } : {}),
      description: vm.description,
      ...(vm.provider ? { provider: vm.provider, gpu: vm.specs?.gpu } : {}),
      gha: vm.gha,
      ...(vm.idle_shutdown ? { idle_shutdown: vm.idle_shutdown } : {}),
      containers: vmContainers,
      ports: vmPorts,
      networks: uniqueNetworks,
      specs: {
        cpu: vm.specs?.cpu ?? null,
        ram_gb: vm.specs?.ram_gb ?? null,
        disk_gb: vm.specs?.disk_gb ?? null,
        ...(vm.specs?.shape ? { shape: vm.specs.shape } : {}),
        ...(vm.specs?.machine_type ? { machine_type: vm.specs.machine_type } : {}),
      },
    };
  }

  // Build old-style services map
  const oldServices: Record<string, any> = {};
  for (const [svcName, svc] of Object.entries(services) as [string, any][]) {
    oldServices[svcName] = {
      category: svc.category,
      vm: svc.vm,
      folder: svc.folder,
      description: svc.description,
      ...(svc.domain ? { domain: svc.domain } : {}),
      ...(svc.port != null ? { port: svc.port } : {}),
      ...(svc.dns ? { dns: svc.dns } : {}),
      ...(svc.upstream ? { upstream: svc.upstream } : {}),
      containers: svc.containers,
      container_names: svc.container_names,
      all_ports: svc.all_ports,
      all_dns: svc.all_dns,
      compose: svc.compose,
      ...(svc.proxy ? { proxy: svc.proxy } : {}),
      ...(svc.declared_ports ? { declared_ports: svc.declared_ports } : {}),
      ...(svc.health ? { health: svc.health } : {}),
      ...(svc.monitoring ? { monitoring: svc.monitoring } : {}),
      ...(svc.backup ? { backup: svc.backup } : {}),
      ...(svc.notifications ? { notifications: svc.notifications } : {}),
      ...(svc.fallback_vm ? { fallback_vm: svc.fallback_vm } : {}),
      ...(svc.flake ? { flake: svc.flake } : {}),
      ...(svc.extra ? { extra: svc.extra } : {}),
    };
  }

  return {
    name: "cloud-data-topology.json",
    data: {
      owner: c.owner ?? {},
      ssh_key: c.ssh_key,
      remote_base: c.remote_base,
      vms: oldVms,
      vpss: c.vpss ?? {},
      storage: c.storage ?? [],
      firewalls: c.firewalls ?? {},
      os_firewalls: c.firewalls?.os ?? {},
      os_firewall_global: c.firewalls?.global ?? {},
      wireguard: c.native?.wireguard ?? {},
      dns: c.dns ?? {},
      services: oldServices,
      native: {
        wireguard: c.native?.wireguard ?? {},
        dns: c.native?.dns ?? {},
        docker: c.native?.docker ?? {},
        monitoring: c.native?.monitoring ?? {},
      },
      deps: c.deps ?? {},
      engine_folder: c.engine_folder ?? "bc-obs_c3-infra-mcp",
    },
  };
}

function deriveConfigs(c: any): DerivedFile {
  const services = c.services as Record<string, any>;
  const vms = c.vms as Record<string, any>;

  // Build services array sorted by name, with vm, category, etc.
  const svcList: any[] = [];
  for (const [svcName, svc] of Object.entries(services)) {
    svcList.push({
      name: svcName,
      category: svc.category,
      vm: svc.vm,
      description: svc.description,
      domain: svc.domain ?? "\u2014",
      ports: svc.compose?.ports ?? [],
      networks: svc.compose?.networks ?? [],
      containers: svc.container_names ?? [],
    });
  }
  svcList.sort((a, b) => a.name.localeCompare(b.name));

  // Build infra and apps groupings
  const infraServices = svcList.filter(s =>
    ["sec", "cloud", "tools", "data"].includes(s.category)
  );
  const appServices = svcList.filter(s =>
    ["app", "mic", "fin", "agi"].includes(s.category)
  );

  return {
    name: "cloud-data-configs.json",
    data: {
      _meta: {
        generated_by: "derive-cloud-data.ts",
        api_route: "GET /c3-api/cloud-data/configs",
        source: "_cloud-data-consolidated.json",
        generated_at: now(),
      },
      services: svcList,
      infra: infraServices,
      apps: appServices,
    },
  };
}

function deriveDeps(c: any): DerivedFile {
  const deps = c.deps ?? {};
  const perService = deps.node?.per_service ?? [];

  return {
    name: "cloud-data-deps.json",
    data: {
      _meta: {
        generated_by: "derive-cloud-data.ts",
        api_route: "GET /c3-api/cloud-data/deps",
        generated_at: now(),
        total_services: perService.length,
        total_packages: Object.keys(deps.node?.merged?.dependencies ?? {}).length +
          Object.keys(deps.node?.merged?.devDependencies ?? {}).length,
      },
      // System deps: flat structure matching existing consumer format
      system: deps.system ?? {},
      ...(deps.build ? { build: deps.build } : {}),
      ...(deps.optional ? { optional: deps.optional } : {}),
      node: {
        merged: deps.node?.merged ?? { dependencies: {}, devDependencies: {} },
        per_service: perService,
      },
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

/** Per-service connection data — resolves service name → IP + port from deploy.host + build.json */
function deriveServiceConnections(c: any): DerivedFile {
  const vms = c.vms as Record<string, any>;
  const services = c.services as Record<string, any>;
  const aliasMap = buildAliasToVm(vms);

  // For each service: resolve deploy.host (ssh alias) → VM → wg_ip, include ports
  const svcMap: Record<string, { ip: string; ports: Record<string, number>; vm: string }> = {};

  for (const [svcName, svc] of Object.entries(services)) {
    const vmEntry = vms[svc.vm];
    if (!vmEntry?.wg_ip) continue;

    // Collect ports: declared_ports (from build.json "ports") takes priority,
    // then supplement with container ports for any roles not already declared
    const ports: Record<string, number> = {};
    if (svc.declared_ports && typeof svc.declared_ports === "object") {
      for (const [k, v] of Object.entries(svc.declared_ports)) {
        if (typeof v === "number") ports[k] = v;
      }
    }
    for (const [role, ct] of Object.entries(svc.containers ?? {})) {
      const port = (ct as any).port;
      if (port && !ports[role]) ports[role] = port;
    }

    svcMap[svcName] = {
      ip: vmEntry.wg_ip,
      ports,
      vm: vmEntry.ssh_alias ?? svc.vm,
    };
  }

  // Also include VMs list for services like dagu that need SSH to all VMs
  const vmList = Object.entries(vms)
    .filter(([, vm]: [string, any]) => vm.wg_ip && vm.ssh_alias)
    .map(([vmId, vm]: [string, any]) => ({
      vm_id: vmId,
      alias: vm.ssh_alias,
      ip: vm.wg_ip,
      user: vm.user ?? "ubuntu",
    }));

  return {
    name: "cloud-data-service-connections.json",
    data: {
      _generated: now(),
      services: svcMap,
      vms: vmList,
    },
  };
}

function main() {
  console.log("derive-cloud-data: reading consolidated file...\n");

  if (!existsSync(INPUT_JSON)) {
    console.error(`FATAL: consolidated file not found at ${INPUT_JSON}`);
    process.exit(1);
  }

  const consolidated = JSON.parse(readFileSync(INPUT_JSON, "utf-8"));

  if (!existsSync(CLOUD_DATA_DIR)) {
    mkdirSync(CLOUD_DATA_DIR, { recursive: true });
  }

  // Run all derivations (19 + per-VM container manifests)
  const derived: DerivedFile[] = [
    ...deriveVmContainerManifests(consolidated),
    deriveServiceConnections(consolidated),
    deriveDnsServices(consolidated),
    deriveCaddyRoutes(consolidated),
    deriveAutheliaAcl(consolidated),
    deriveHomeManager(consolidated),
    deriveGhaConfig(consolidated),
    deriveWireguardPeers(consolidated),
    deriveFirewallRules(consolidated),
    deriveMonitoringTargets(consolidated),
    deriveBackupTargets(consolidated),
    deriveContainerResources(consolidated),
    deriveLogRouting(consolidated),
    deriveCloudflareDns(consolidated),
    deriveMatomoSites(consolidated),
    deriveNtfyAcl(consolidated),
    deriveTopology(consolidated),
    deriveConfigs(consolidated),
    deriveDeps(consolidated),
    deriveDatabases(consolidated),
  ];

  // Write all files (inject DO NOT EDIT header into each)
  const DO_NOT_EDIT = "AUTO-GENERATED by derive-cloud-data.ts — DO NOT EDIT. Source: cloud/a_solutions/bc-obs_c3-infra-mcp/src/engines/derive-cloud-data.ts";
  const summary: string[] = [];
  for (const file of derived) {
    const path = join(CLOUD_DATA_DIR, file.name);
    const output = typeof file.data === "object" && !Array.isArray(file.data)
      ? { _warning: DO_NOT_EDIT, ...file.data }
      : file.data;
    const json = JSON.stringify(output, null, 2) + "\n";
    writeFileSync(path, json);

    // Count top-level entries for summary
    const data = file.data as any;
    let countStr = "";
    if (data.services && typeof data.services === "object") {
      const count = Array.isArray(data.services) ? data.services.length : Object.keys(data.services).length;
      countStr = `${count} entries`;
    } else if (data.rules) {
      countStr = `${Array.isArray(data.rules) ? data.rules.length : Object.keys(data.rules).length} rules`;
    } else if (data.vms && typeof data.vms === "object") {
      const count = Array.isArray(data.vms) ? data.vms.length : Object.keys(data.vms).length;
      countStr = `${count} VMs`;
    } else if (data.targets) {
      countStr = `${data.targets.length} targets`;
    } else if (data.records) {
      countStr = `${data.records.length} records`;
    } else if (data.sites) {
      countStr = `${data.sites.length} sites`;
    } else if (data.topics) {
      countStr = `${Object.keys(data.topics).length} topics`;
    } else if (data.mesh_peers) {
      countStr = `${data.mesh_peers.length} peers`;
    } else if (data.routes) {
      countStr = `${data.routes.length} routes`;
    }

    summary.push(`  ${file.name.padEnd(42)} ${countStr}`);
  }

  // Generate manifest.json for the web dashboard sidebar
  const manifestEntries = [
    { file: "_cloud-data-consolidated.json", name: "_cloud data consolidated" },
    ...derived.map((f) => ({
      file: f.name,
      name: f.name.replace(/\.json$/, "").replace(/cloud-data-/, "cloud data ").replace(/-/g, " "),
    })),
  ];
  const manifestJson = JSON.stringify(manifestEntries, null, 2) + "\n";
  writeFileSync(join(CLOUD_DATA_DIR, "manifest.json"), manifestJson);

  console.log(`derive-cloud-data: wrote ${derived.length} files + manifest.json:\n`);
  for (const line of summary) {
    console.log(line);
  }

  console.log("\nderive-cloud-data: done.");
}

main();
