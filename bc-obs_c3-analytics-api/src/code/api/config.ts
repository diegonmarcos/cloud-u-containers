// Loads runtime config from env vars injected by compose.nix from cloud-data.
// Nothing is hardcoded here — every URL, port, and limit comes from build.json
// → cloud-data → BACKENDS_JSON / SITES_JSON / LIMITS_JSON.

export interface BackendCfg {
  url: string;
  service: string;
  methods: string[];
  auth_header_env: string | null;
}

export interface SiteCfg {
  id: string;          // public sid (?sid=<uuid>)
  origins: string[];   // allowed Origin headers
  matomo_idsite?: number | string;
  umami_website_id?: string;
  openobserve_stream?: string;
}

export interface Limits {
  max_body_bytes: number;
  max_ingest_lines: number;
  rate_per_ip_per_min: number;
  rate_per_sid_per_min: number;
  tracker_cache_seconds: number;
  request_timeout_ms: number;
}

export interface AppConfig {
  host: string;
  port: number;
  basePath: string;
  backends: Record<string, BackendCfg>;
  sites: SiteCfg[];
  limits: Limits;
  // Resolved auth headers for each backend slug, keyed by slug.
  // Looked up from process.env at boot, so secrets stay in env not in JSON.
  resolvedAuthHeaders: Record<string, string | undefined>;
}

function readJson<T>(name: string, fallback: T): T {
  const raw = process.env[name];
  if (!raw) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch (e) {
    throw new Error(`${name} env var is not valid JSON: ${(e as Error).message}`);
  }
}

export function loadConfig(): AppConfig {
  const backends = readJson<Record<string, BackendCfg>>('BACKENDS_JSON', {});
  const sites = readJson<SiteCfg[]>('SITES_JSON', []);
  const limits = readJson<Limits>('LIMITS_JSON', {
    max_body_bytes: 1048576,
    max_ingest_lines: 5000,
    rate_per_ip_per_min: 60,
    rate_per_sid_per_min: 1000,
    tracker_cache_seconds: 300,
    request_timeout_ms: 5000,
  });

  const resolvedAuthHeaders: Record<string, string | undefined> = {};
  for (const [slug, cfg] of Object.entries(backends)) {
    if (cfg.auth_header_env) {
      resolvedAuthHeaders[slug] = process.env[cfg.auth_header_env];
    }
  }

  return {
    host: process.env.HOST ?? '0.0.0.0',
    port: Number(process.env.PORT ?? 8085),
    basePath: process.env.BASE_PATH ?? '/c3a',
    backends,
    sites,
    limits,
    resolvedAuthHeaders,
  };
}
