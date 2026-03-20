import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

export interface ProxyPathOverride {
  upstream?: string;
  auth?: string;
  strip_prefix?: boolean;
}

export interface ProxyConfig {
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
  // Declarative infrastructure fields
  proxy?: ProxyConfig;
  ports?: Record<string, PortConfig>;
  health?: HealthConfig;
  monitoring?: MonitoringConfig;
  backup?: BackupConfig;
  notifications?: NotificationsConfig;
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

      const expectedFolder = CATEGORY_PREFIX[category]
        ? `${CATEGORY_PREFIX[category]}${name}`
        : name;
      const flake = folder !== expectedFolder
        ? folder.replace(/^[a-z]{2}-[a-z]{3}_/, "")
        : undefined;

      entries.push({
        name,
        category,
        vm: host,
        domain: bj.domain,
        description: bj.description || "",
        flake,
        folder,
        // Pass through declarative infrastructure fields if present
        ...(bj.proxy ? { proxy: bj.proxy } : {}),
        ...(bj.ports ? { ports: bj.ports } : {}),
        ...(bj.health ? { health: bj.health } : {}),
        ...(bj.monitoring ? { monitoring: bj.monitoring } : {}),
        ...(bj.backup ? { backup: bj.backup } : {}),
        ...(bj.notifications ? { notifications: bj.notifications } : {}),
      });
    } catch {
      console.warn(`  WARN: invalid build.json in ${folder}`);
    }
  }

  return entries;
}
