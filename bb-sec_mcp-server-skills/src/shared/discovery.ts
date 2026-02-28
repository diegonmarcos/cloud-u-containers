import { getConfig, getVmSshAlias } from "./config.js";
import { rawHttpRequest, getBearerToken } from "./http.js";

interface ServiceInfo {
  name: string;
  domain?: string;
  vm: string;
  alias?: string;
  category: string;
  hasSpec?: boolean;
  specUrl?: string;
}

interface SpecCache {
  data: unknown;
  fetchedAt: number;
}

const specCache = new Map<string, SpecCache>();
const SPEC_TTL = 5 * 60 * 1000; // 5 minutes

// Known service domains — maps service name to domain
// This replaces the Rust API's hardcoded service registry
const SERVICE_DOMAINS: Record<string, string> = {
  authelia: "auth.diegonmarcos.com",
  caddy: "proxy.diegonmarcos.com",
  vaultwarden: "vault.diegonmarcos.com",
  ntfy: "rss.diegonmarcos.com",
  matomo: "analytics.diegonmarcos.com",
  mailu: "mail.diegonmarcos.com",
  syncthing: "sync.diegonmarcos.com",
  radicale: "cal.diegonmarcos.com",
  photoprism: "photos.diegonmarcos.com",
  nocodb: "db.diegonmarcos.com",
  "code-server": "ide.diegonmarcos.com",
  affine: "drive-notes-affine.diegonmarcos.com",
  windmill: "windmill.diegonmarcos.com",
};

// Known spec paths per service
const SPEC_PATHS: Record<string, string> = {
  matomo: "/index.php?module=API&method=API.getReportMetadata&format=json",
  vaultwarden: "/api/config",
  ntfy: "/docs",
  photoprism: "/api/v1/config",
  nocodb: "/api/v1/meta/tables",
  syncthing: "/rest/system/config",
  authelia: "/api/configuration",
};

export function listServices(): ServiceInfo[] {
  const config = getConfig();
  const services: ServiceInfo[] = [];

  for (const [name, svc] of Object.entries(config.services)) {
    const alias = svc.vm === "local" || svc.vm === "all"
      ? svc.vm
      : getVmSshAlias(svc.vm);

    const domain = SERVICE_DOMAINS[name];
    const hasSpec = name in SPEC_PATHS;

    services.push({
      name,
      domain,
      vm: svc.vm,
      alias,
      category: svc.category,
      hasSpec,
      specUrl: hasSpec && domain ? `https://${domain}${SPEC_PATHS[name]}` : undefined,
    });
  }

  return services;
}

export function getService(serviceName: string): ServiceInfo | null {
  const config = getConfig();
  const svc = config.services[serviceName];
  if (!svc) return null;

  const alias = svc.vm === "local" || svc.vm === "all"
    ? svc.vm
    : getVmSshAlias(svc.vm);

  const domain = SERVICE_DOMAINS[serviceName];
  const hasSpec = serviceName in SPEC_PATHS;

  return {
    name: serviceName,
    domain,
    vm: svc.vm,
    alias,
    category: svc.category,
    hasSpec,
    specUrl: hasSpec && domain ? `https://${domain}${SPEC_PATHS[serviceName]}` : undefined,
  };
}

export function probeSpec(serviceName: string): { ok: boolean; spec: unknown; error?: string } {
  // Check cache
  const cached = specCache.get(serviceName);
  if (cached && Date.now() - cached.fetchedAt < SPEC_TTL) {
    return { ok: true, spec: cached.data };
  }

  const domain = SERVICE_DOMAINS[serviceName];
  if (!domain) {
    return { ok: false, spec: null, error: `No domain configured for service: ${serviceName}` };
  }

  const specPath = SPEC_PATHS[serviceName];
  if (!specPath) {
    return { ok: false, spec: null, error: `No spec path known for service: ${serviceName}` };
  }

  const url = `https://${domain}${specPath}`;
  const token = getBearerToken();
  const headers: Record<string, string> = {};
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const result = rawHttpRequest("GET", url, undefined, 15_000, Object.keys(headers).length ? headers : undefined);

  if (!result.ok) {
    return { ok: false, spec: null, error: `HTTP ${result.status}: ${result.error}` };
  }

  // Cache the result
  specCache.set(serviceName, { data: result.data, fetchedAt: Date.now() });

  return { ok: true, spec: result.data };
}

export function getAllSpecs(): { ok: boolean; specs: Record<string, unknown>; errors: Record<string, string> } {
  const specs: Record<string, unknown> = {};
  const errors: Record<string, string> = {};

  for (const serviceName of Object.keys(SPEC_PATHS)) {
    if (!SERVICE_DOMAINS[serviceName]) continue;

    const result = probeSpec(serviceName);
    if (result.ok) {
      specs[serviceName] = result.spec;
    } else {
      errors[serviceName] = result.error ?? "unknown error";
    }
  }

  return { ok: true, specs, errors };
}
