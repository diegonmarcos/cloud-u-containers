import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

export interface ProxyPathOverride {
  upstream?: string;
  auth?: string;
  strip_prefix?: boolean;
}

// New schema: proxy.primary — the custom/vanity route
export interface ProxyPrimaryConfig {
  domain?: string;
  type?: "subdomain" | "path" | "l4";
  parent_domain?: string;
  base_path?: string;
  auth?: string;
  paths?: Record<string, ProxyPathOverride>;
  github_pages?: string;
  landing_page?: string;
  tls_skip_verify?: boolean;
  max_upload?: string;
  streaming?: boolean;
  timeout?: string;
}

// New schema: proxy.app_hub — standardized app.diegonmarcos.com/{name} route
export interface AppHubConfig {
  enabled?: boolean;   // default: true (false for infra/backend services)
  auth?: string;       // inherits from primary.auth if not set
}

// Combined proxy config — supports both old flat format and new primary/app_hub format
export interface ProxyConfig {
  // New schema fields
  primary?: ProxyPrimaryConfig;
  app_hub?: AppHubConfig | false;

  // Legacy flat fields (backward compat during migration)
  upstream?: string;
  auth?: string;
  paths?: Record<string, ProxyPathOverride>;
  github_pages?: string;
  landing_page?: string;
  tls_skip_verify?: boolean;
  max_upload?: string;
  streaming?: boolean;
  timeout?: string;
  type?: "subdomain" | "path" | "l4";
  parent_domain?: string;
  base_path?: string;
  additional_routes?: unknown[];
}

export interface PortConfig {
  container: number;
  host?: number;
  proto?: "tcp" | "udp";
  public?: boolean;
}

export interface HealthConfig {
  path?: string;
  interval?: string;
  timeout?: string;
  expected_status?: number;
}

export interface MonitoringConfig {
  tls_check?: boolean;
  dns_check?: boolean;
  endpoint_check?: boolean;
}

export interface BackupConfig {
  enabled?: boolean;
  volumes?: string[];
  schedule?: string;
  retention?: string;
}

export interface NotificationsConfig {
  topic?: string;
  on_failure?: boolean;
  on_recovery?: boolean;
}

export interface BuildJsonEntry {
  name: string;
  category: string;
  vm: string;
  domain?: string;
  description: string;
  flake?: string;
  folder: string;
  // Standardized routing fields
  port?: number;               // Main listening port (REQUIRED for routable services)
  dns?: string;                // Internal DNS name, e.g. "{name}.app" (REQUIRED for routable services)
  // Declarative infrastructure fields
  proxy?: ProxyConfig;
  ports?: Record<string, PortConfig>;
  health?: HealthConfig;
  monitoring?: MonitoringConfig;
  backup?: BackupConfig;
  notifications?: NotificationsConfig;
  // Deploy overrides
  fallback_vm?: string;          // deploy.fallback_host → resolved to VM ID
  // Pass-through: any extra top-level fields from build.json (models, notes, etc.)
  extra?: Record<string, unknown>;
}

const CATEGORY_PREFIX: Record<string, string> = {
  app: "aa-sui_",
  mic: "ab-mic_",
  fin: "ac-fin_",
  agi: "ad-agi_",
  cloud: "ba-clo_",
  sec: "bb-sec_",
  tools: "bc-obs_",
  data: "ca-dat_",
};

const PREFIX_CATEGORY: Record<string, string> = {};
for (const [cat, prefix] of Object.entries(CATEGORY_PREFIX)) {
  PREFIX_CATEGORY[prefix] = cat;
}

export { CATEGORY_PREFIX, PREFIX_CATEGORY };

function deriveCategory(folder: string): string | undefined {
  for (const [prefix, cat] of Object.entries(PREFIX_CATEGORY)) {
    if (folder.startsWith(prefix)) return cat;
  }
  return undefined;
}

export function scanBuildJsons(solutionsDir: string): BuildJsonEntry[] {
  const entries: BuildJsonEntry[] = [];

  let dirs: string[];
  try {
    dirs = readdirSync(solutionsDir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith("z_archive") && !d.name.startsWith("."))
      .map((d) => d.name);
  } catch {
    return entries;
  }

  for (const folder of dirs) {
    const bjPath = join(solutionsDir, folder, "build.json");
    if (!existsSync(bjPath)) continue;

    try {
      const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
      const name = bj.name;
      if (!name) continue;

      const category = bj.category || deriveCategory(folder) || "tools";
      const host = bj.deploy?.host ?? "local";
      const fallbackHost = bj.deploy?.fallback_host;

      const expectedFolder = CATEGORY_PREFIX[category]
        ? `${CATEGORY_PREFIX[category]}${name}`
        : name;
      const flake = folder !== expectedFolder
        ? folder.replace(/^[a-z]{2}-[a-z]{3}_/, "")
        : undefined;

      // Derive dns from name if not explicitly set
      const port: number | undefined = bj.port;
      const dns: string | undefined = bj.dns ?? (port ? `${name}.app` : undefined);

      // Collect extra top-level fields not handled above
      const knownKeys = new Set([
        "name", "description", "category", "domain", "deploy", "dns", "port",
        "ports", "proxy", "health", "monitoring", "backup", "notifications",
        "docker", "secrets", "build", "compose", "lifecycle", "terraform",
        "multi_vm", "frozen", "version",
      ]);
      const extra: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(bj)) {
        if (!knownKeys.has(k)) extra[k] = v;
      }

      entries.push({
        name,
        category,
        vm: host,
        domain: bj.domain,
        description: bj.description || "",
        flake,
        folder,
        // Standardized routing fields
        ...(port != null ? { port } : {}),
        ...(dns ? { dns } : {}),
        // Pass through declarative infrastructure fields if present
        ...(bj.proxy ? { proxy: bj.proxy } : {}),
        ...(bj.ports ? { ports: bj.ports } : {}),
        ...(bj.health ? { health: bj.health } : {}),
        ...(bj.monitoring ? { monitoring: bj.monitoring } : {}),
        ...(bj.backup ? { backup: bj.backup } : {}),
        ...(bj.notifications ? { notifications: bj.notifications } : {}),
        // Deploy overrides
        ...(fallbackHost ? { fallback_vm: fallbackHost } : {}),
        // Extra service-specific fields (models, notes, etc.)
        ...(Object.keys(extra).length > 0 ? { extra } : {}),
      });
    } catch {
      console.warn(`  WARN: invalid build.json in ${folder}`);
    }
  }

  return entries;
}
