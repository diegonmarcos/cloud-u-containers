// ── Inventory Routes — "What exists" ──
// Service catalog, topology, config, and discovery

import { readFileSync, existsSync, readdirSync } from "fs";
import { join, dirname } from "path";
import type { FastifyInstance } from "fastify";
import { listServices, getService, probeSpec, getAllSpecs } from "../../shared/discovery.js";
import { getDriftReport, getConfig, getServiceFolder } from "../../shared/config.js";
import { getConfigFile } from "../../shared/files.js";
import { CONFIG_PATH, CONFIGS_PATH, DEPS_PATH, FRONT_DEPS_PATH } from "../../shared/paths.js";

export async function registerInventoryRoutes(app: FastifyInstance) {
  // ── Services (from services.ts) ──

  app.get("/services", { schema: { tags: ["Inventory"] } }, async () => {
    return listServices();
  });

  app.get<{ Params: { service: string } }>(
    "/services/:service",
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const } }, required: ["service"] } } },
    async (req, reply) => {
      const info = getService(req.params.service);
      if (!info) {
        reply.code(404).send({ error: `Unknown service: ${req.params.service}` });
        return;
      }
      return info;
    },
  );

  app.get<{ Params: { service: string } }>(
    "/services/:service/spec",
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const } }, required: ["service"] } } },
    async (req, reply) => {
      const result = probeSpec(req.params.service);
      if (!result.ok) {
        reply.code(404).send({ error: result.error });
        return;
      }
      return result.spec;
    },
  );

  app.get("/services/all/specs", { schema: { tags: ["Inventory"] } }, async () => {
    return getAllSpecs();
  });

  // ── Topology (serves cloud-data-topology.json directly) ──

  app.get("/cloud-data/topology", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    return JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
  });

  app.get("/cloud-data/topology/drift", { schema: { tags: ["Inventory"] } }, async () => {
    const drift = getDriftReport();
    const parts: string[] = [];
    if (drift.onDiskOnly.length > 0) parts.push(`${drift.onDiskOnly.length} on disk only: ${drift.onDiskOnly.join(", ")}`);
    if (drift.configOnly.length > 0) parts.push(`${drift.configOnly.length} in config only: ${drift.configOnly.join(", ")}`);
    if (parts.length === 0) parts.push("No drift detected.");
    return { onDiskOnly: drift.onDiskOnly, configOnly: drift.configOnly, summary: parts.join(" | ") };
  });

  // ── Configs (serves cloud-data-configs.json directly) ──

  app.get("/cloud-data/configs", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIGS_PATH)) { reply.code(404).send({ error: "cloud-data-configs.json not generated yet" }); return; }
    return JSON.parse(readFileSync(CONFIGS_PATH, "utf-8"));
  });

  // ── Deps (serves cloud-data-deps.json — consolidated node packages grouped by language) ──

  app.get("/cloud-data/deps", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(DEPS_PATH)) { reply.code(404).send({ error: "cloud-data-deps.json not generated yet. Run: build.sh config" }); return; }
    return JSON.parse(readFileSync(DEPS_PATH, "utf-8"));
  });

  app.get("/cloud-data/deps/node", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(DEPS_PATH)) { reply.code(404).send({ error: "cloud-data-deps.json not generated yet" }); return; }
    const deps = JSON.parse(readFileSync(DEPS_PATH, "utf-8"));
    return deps.node ?? {};
  });

  app.get("/cloud-data/deps/node/merged", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(DEPS_PATH)) { reply.code(404).send({ error: "cloud-data-deps.json not generated yet" }); return; }
    const deps = JSON.parse(readFileSync(DEPS_PATH, "utf-8"));
    return deps.node?.merged ?? {};
  });

  app.get("/cloud-data/deps/front", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(FRONT_DEPS_PATH)) { reply.code(404).send({ error: "front-deps.json not generated yet. Run: front/build.sh deps or cloud build.sh config" }); return; }
    return JSON.parse(readFileSync(FRONT_DEPS_PATH, "utf-8"));
  });

  // ── DNS Registry (container name → WG IP, for Hickory DNS auto-generation) ──

  app.get("/cloud-data/dns-services", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
    const services: Record<string, { ip: string; desc: string }> = {};
    const vms: Record<string, string> = {};

    // Use getConfig() which merges build.json discovery + config.json fallback
    const config = getConfig();
    const solutionsDir = join(dirname(CONFIG_PATH), "a_solutions");

    for (const [svcName, svc] of Object.entries(config.services)) {
      const vm = topo.vms?.[svc.vm];
      if (!vm?.wg_ip) continue;
      const ip: string = vm.wg_ip;
      const desc: string = svc.description ?? svcName;

      // Register service name
      services[svcName] = { ip, desc };

      // Extract .app DNS names from build.json proxy config
      const folder = svc.folder ?? getServiceFolder(svcName);
      const bjPath = join(solutionsDir, folder, "build.json");
      if (existsSync(bjPath)) {
        try {
          const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
          const upstreams: string[] = [];
          if (bj.proxy?.upstream) upstreams.push(bj.proxy.upstream);
          for (const l4 of (bj.proxy?.l4_ports ?? [])) {
            if (l4.upstream) upstreams.push(l4.upstream);
          }
          for (const u of upstreams) {
            const m = u.match(/^(?:https?:\/\/)?([a-z0-9-]+)\.app/);
            if (m && m[1]) services[m[1]] = { ip, desc };
          }
        } catch { /* skip */ }
      }
    }

    // PTR reverse map: last WG octet → VM alias (for Hickory vms attrset)
    for (const [, vm] of Object.entries(topo.vms ?? {})) {
      const v = vm as any;
      if (!v.wg_ip) continue;
      const lastOctet = v.wg_ip.split(".").pop();
      if (lastOctet) vms[lastOctet] = v.ssh_alias ?? "";
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/dns-services",
      suffix: "app",
      services,
      vms,
    };
  });

  // ── Caddy Routes (derived from topology proxy fields → caddy-routes.json) ──

  app.get("/cloud-data/caddy-routes", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    // Uses getConfig() which merges build.json (source of truth) + config.json (fallback)
    const config = getConfig();
    const solutionsDir = join(dirname(CONFIG_PATH), "a_solutions");

    const routes: any[] = [];
    const path_routes: any[] = [];
    const github_pages_proxies: any[] = [];
    const l4_routes: any[] = [];
    const mcp_routes: any[] = [];
    const special: Record<string, any> = {};

    for (const [svcName, svc] of Object.entries(config.services ?? {})) {
      // Enrich with build.json proxy config (discovered services may not have proxy in config.json)
      const s = svc as any;
      if (!s.proxy) {
        const folder = s.folder ?? getServiceFolder(svcName);
        const bjPath = join(solutionsDir, folder, "build.json");
        if (existsSync(bjPath)) {
          try {
            const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
            if (bj.proxy) s.proxy = bj.proxy;
            if (bj.domain && !s.domain) s.domain = bj.domain;
          } catch {}
        }
      }
      const proxy = s.proxy;
      if (!proxy) continue;

      const domain = s.domain;
      const route: any = {
        service: svcName,
        domain,
        upstream: proxy.upstream,
        auth: proxy.auth ?? "two_factor",
        description: s.description ?? "",
      };

      // Optional fields
      if (proxy.landing_page) route.landing_page = proxy.landing_page;
      if (proxy.tls_skip_verify) route.tls_skip_verify = true;
      if (proxy.max_upload) route.max_upload = proxy.max_upload;
      if (proxy.timeout) route.timeout = proxy.timeout;
      if (proxy.streaming) route.streaming = true;
      if (proxy.paths) route.paths = proxy.paths;
      if (proxy.github_pages) route.github_pages = proxy.github_pages;

      // L4 TCP passthrough (mail ports)
      if (proxy.l4_ports) {
        for (const l4 of proxy.l4_ports) {
          l4_routes.push({ port: l4.port, upstream: l4.upstream, service: svcName, comment: l4.comment ?? "" });
        }
      }

      // Route type classification
      const type = proxy.type ?? "subdomain";

      if (type === "path" && proxy.streaming) {
        // MCP streaming endpoints
        mcp_routes.push({
          service: svcName,
          path: proxy.base_path,
          upstream: proxy.upstream,
          parent_domain: proxy.parent_domain,
        });
      } else if (type === "path") {
        path_routes.push({
          ...route,
          parent_domain: proxy.parent_domain,
          base_path: proxy.base_path,
        });
      } else if (proxy.github_pages && !proxy.upstream) {
        github_pages_proxies.push({
          service: svcName,
          domain,
          path: proxy.github_pages,
        });
      } else if (proxy.auth === "ntfy-3tier") {
        special.ntfy = route;
      } else {
        routes.push(route);
      }
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/caddy-routes",
      routes,
      path_routes,
      github_pages_proxies,
      l4_routes,
      mcp_routes,
      special,
    };
  });

  // ── Authelia ACL (derived from topology proxy.auth fields → authelia-acl.json) ──

  app.get("/cloud-data/authelia-acl", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const rules: any[] = [];

    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      const proxy = s.proxy;
      if (!proxy || !s.domain) continue;

      const domain = s.domain;
      const auth = proxy.auth ?? "two_factor";
      if (auth === "ntfy-3tier") continue; // ntfy has custom auth, not Authelia-managed

      const rule: any = { domain, policy: auth, service: svcName };

      // Path-specific overrides (e.g. /api/* bypass, /admin two_factor)
      if (proxy.paths) {
        const bypass_resources: string[] = [];
        const two_factor_resources: string[] = [];
        for (const [path, override] of Object.entries(proxy.paths)) {
          const o = override as any;
          const pathAuth = o.auth ?? "two_factor";
          const regex = "^" + path.replace(/\*/g, ".*");
          if (pathAuth === "bypass" || pathAuth === "public") bypass_resources.push(regex);
          else if (pathAuth === "two_factor") two_factor_resources.push(regex);
        }
        if (bypass_resources.length > 0) rule.resources_bypass = bypass_resources;
        if (two_factor_resources.length > 0) rule.resources_two_factor = two_factor_resources;
      }

      rules.push(rule);
    }

    // Default catch-all
    rules.push({ domain: "*.diegonmarcos.com", policy: "two_factor", service: "_default" });

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/authelia-acl",
      rules,
    };
  });

  // ── Monitoring Targets (derived from topology health/monitoring fields) ──

  app.get("/cloud-data/monitoring-targets", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const endpoint_checks: any[] = [];
    const dns_checks: string[] = [];
    const tls_checks: string[] = [];
    const vms: any[] = [];

    // VM-level checks
    for (const [, vm] of Object.entries(topo.vms ?? {})) {
      const v = vm as any;
      if (!v.wg_ip) continue;
      vms.push({ ip: v.wg_ip, name: v.ssh_alias ?? "", user: v.user ?? "diego" });
    }

    // Service-level checks
    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      const domain = s.domain;
      if (!domain) continue;

      const monitoring = s.monitoring ?? {};
      const health = s.health ?? {};

      if (monitoring.endpoint_check !== false && health.path) {
        endpoint_checks.push({
          url: `https://${domain}${health.path}`,
          name: s.description ?? svcName,
          expected_status: health.expected_status ?? 200,
        });
      }

      if (monitoring.dns_check) dns_checks.push(domain);
      if (monitoring.tls_check) tls_checks.push(domain);
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/monitoring-targets",
      endpoint_checks,
      dns_checks,
      tls_checks,
      vms,
    };
  });

  // ── Firewall Rules (aggregated ports per VM from topology) ──

  app.get("/cloud-data/firewall-rules", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const vms: Record<string, { ingress: any[] }> = {};

    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      const vm = topo.vms?.[s.vm];
      if (!vm?.ssh_alias) continue;

      const alias = vm.ssh_alias;
      if (!vms[alias]) vms[alias] = { ingress: [] };

      const declaredPorts = s.declared_ports ?? {};
      for (const [, portCfg] of Object.entries(declaredPorts)) {
        const p = portCfg as any;
        if (p.public) {
          vms[alias].ingress.push({
            port: p.host ?? p.container,
            proto: p.proto ?? "tcp",
            service: svcName,
          });
        }
      }
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/firewall-rules",
      vms,
    };
  });

  // ── Backup Targets (services with backup.enabled) ──

  app.get("/cloud-data/backup-targets", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const targets: any[] = [];

    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      const backup = s.backup;
      if (!backup?.enabled) continue;

      const vm = topo.vms?.[s.vm];
      targets.push({
        service: svcName,
        vm: vm?.ssh_alias ?? s.vm,
        volumes: backup.volumes ?? [],
        schedule: backup.schedule ?? "0 3 * * *",
        retention: backup.retention ?? "30d",
      });
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/backup-targets",
      targets,
    };
  });

  // ── WireGuard Peers (derived from topology VMs with wg_ip) ──

  app.get("/cloud-data/wireguard-peers", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const peers: any[] = [];
    for (const [vmId, vm] of Object.entries(topo.vms ?? {})) {
      const v = vm as any;
      if (!v.wg_ip) continue;
      peers.push({
        vm_id: vmId,
        name: v.ssh_alias ?? vmId,
        wg_ip: v.wg_ip,
        public_ip: v.ip ?? "",
        user: v.user ?? "diego",
      });
    }

    // WireGuard mesh config from topology
    const wg = topo.wireguard ?? topo.native?.wireguard ?? {};

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/wireguard-peers",
      hub: wg.hub ?? null,
      peers: wg.peers ?? peers,
      mesh_peers: peers,
    };
  });

  // ── ntfy ACL (derived from topology notifications fields) ──

  app.get("/cloud-data/ntfy-acl", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const topics: Record<string, { publishers: string[]; desc: string }> = {};

    // System topics (always present)
    for (const t of ["syslog", "github-releases", "alerts", "health", "backups"]) {
      topics[t] = { publishers: ["system"], desc: `System topic: ${t}` };
    }

    // Service-declared topics
    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      const topic = s.notifications?.topic;
      if (!topic) continue;
      if (!topics[topic]) topics[topic] = { publishers: [], desc: "" };
      topics[topic].publishers.push(svcName);
      if (!topics[topic].desc) topics[topic].desc = `Topic for ${svcName}`;
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/ntfy-acl",
      topics,
    };
  });

  // ── Cloudflare DNS (derived from topology services with domains) ──

  app.get("/cloud-data/cloudflare-dns", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const records: any[] = [];
    const seenDomains = new Set<string>();

    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      let domain = s.domain;
      if (!domain) continue;

      // Extract just the subdomain from full domain (e.g. "api.diegonmarcos.com/c3-api" → "api.diegonmarcos.com")
      domain = domain.split("/")[0];
      if (seenDomains.has(domain)) continue;
      seenDomains.add(domain);

      // Path-based routes use parent_domain
      const proxyDomain = s.proxy?.parent_domain ?? domain;
      if (proxyDomain !== domain) {
        if (seenDomains.has(proxyDomain)) continue;
        seenDomains.add(proxyDomain);
        records.push({ name: proxyDomain, type: "CNAME", content: "diegonmarcos.com", proxied: true, service: svcName });
      } else {
        records.push({ name: domain, type: "CNAME", content: "diegonmarcos.com", proxied: true, service: svcName });
      }
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/cloudflare-dns",
      zone: "diegonmarcos.com",
      records,
    };
  });

  // ── Matomo Sites (services with domains that have analytics tracking) ──

  app.get("/cloud-data/matomo-sites", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const sites: any[] = [];
    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      if (!s.domain) continue;
      const domain = s.domain.split("/")[0];
      sites.push({
        name: s.description ?? svcName,
        url: `https://${domain}`,
        service: svcName,
      });
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/matomo-sites",
      sites,
    };
  });

  // ── Container Resources (derived from topology — mem/cpu per service) ──

  app.get("/cloud-data/container-resources", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const services: Record<string, any> = {};
    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      const vm = topo.vms?.[s.vm];
      if (!vm) continue;
      services[svcName] = {
        vm: vm.ssh_alias ?? s.vm,
        vm_ram_gb: vm.specs?.ram_gb ?? null,
        vm_cpu: vm.specs?.cpu ?? null,
        containers: s.containers ?? [],
        resources: s.resources ?? null,
      };
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/container-resources",
      services,
    };
  });

  // ── Log Routing (derived from topology — container → log config) ──

  app.get("/cloud-data/log-routing", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-data-topology.json not generated yet" }); return; }
    const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));

    const routes: Record<string, any[]> = {};
    for (const [svcName, svc] of Object.entries(topo.services ?? {})) {
      const s = svc as any;
      const vm = topo.vms?.[s.vm];
      if (!vm?.ssh_alias) continue;
      const alias = vm.ssh_alias;
      if (!routes[alias]) routes[alias] = [];
      for (const container of (s.containers ?? [])) {
        routes[alias].push({
          container,
          service: svcName,
          log_level: s.log_level ?? "info",
        });
      }
    }

    return {
      _generated: new Date().toISOString(),
      _source: "cloud-data-topology.json via /cloud-data/log-routing",
      vms: routes,
    };
  });

  // ── Files: config (from files.ts) ──

  app.get<{ Params: { service: string } }>(
    "/files/config/:service",
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const } }, required: ["service"] } } },
    async (req) => {
      return { content: getConfigFile(req.params.service) };
    },
  );

  app.get<{ Params: { service: string; file: string } }>(
    "/files/config/:service/:file",
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const }, file: { type: "string" as const } }, required: ["service", "file"] } } },
    async (req) => {
      return { content: getConfigFile(req.params.service, req.params.file) };
    },
  );
}
// rebuild 1774202309
