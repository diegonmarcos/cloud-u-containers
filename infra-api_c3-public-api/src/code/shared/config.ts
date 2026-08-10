// Runtime config for c3-public-api.
// Nothing is hardcoded: every URL, port, and limit comes from build.json
// -> 1_configs/dist/build-c3-public-api.json -> compose.nix env vars.
//
// Two delivery layers:
//   1. Analytics passthrough — BACKENDS_JSON (matomo/umami/openobserve).
//      Same shape as c3-analytics-api. Public, rate-limited.
//   2. Mail bridge — SMTP_HOST/SMTP_PORT + SMTP_SHADOW_HOST/SMTP_SHADOW_PORT.
//      Bearer-gated upstream by Caddy (introspect-proxy validates the JWT).

export interface BackendCfg {
  url: string;
  service: string;
  methods: string[];
  auth_header_env: string | null;
}

export interface Limits {
  max_body_bytes: number;
  max_ingest_lines: number;
  rate_per_ip_per_min: number;
  rate_per_sid_per_min: number;
  request_timeout_ms: number;
}

export interface MailCfg {
  primary: { host: string; port: number };
  shadow: { host: string; port: number } | null;
  heloDomain: string;
  defaultUser: string;
}

export interface AppConfig {
  host: string;
  port: number;
  basePath: string;
  backends: Record<string, BackendCfg>;
  limits: Limits;
  mail: MailCfg;
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

function readInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n)) {
    throw new Error(`${name} env var is not a number: ${raw}`);
  }
  return n;
}

export function loadConfig(): AppConfig {
  const backends = readJson<Record<string, BackendCfg>>("BACKENDS_JSON", {});
  const limits = readJson<Limits>("LIMITS_JSON", {
    max_body_bytes: 104857600,
    max_ingest_lines: 5000,
    rate_per_ip_per_min: 60,
    rate_per_sid_per_min: 1000,
    request_timeout_ms: 5000,
  });

  const resolvedAuthHeaders: Record<string, string | undefined> = {};
  for (const [slug, cfg] of Object.entries(backends)) {
    if (cfg.auth_header_env) {
      resolvedAuthHeaders[slug] = process.env[cfg.auth_header_env];
    }
  }

  const smtpHost = process.env.SMTP_HOST;
  const smtpPort = readInt("SMTP_PORT", 25);
  const shadowHost = process.env.SMTP_SHADOW_HOST;
  const shadowPort = readInt("SMTP_SHADOW_PORT", 2025);

  const mail: MailCfg = {
    primary: {
      host: smtpHost ?? "",
      port: smtpPort,
    },
    shadow: shadowHost ? { host: shadowHost, port: shadowPort } : null,
    heloDomain: process.env.SMTP_HELO_DOMAIN ?? "c3-public-api.local",
    defaultUser: process.env.SMTP_USER ?? "cloudflare@localhost",
  };

  return {
    host: process.env.HOST ?? "0.0.0.0",
    port: readInt("PORT", 8087),
    basePath: process.env.BASE_PATH ?? "/c3-public-api",
    backends,
    limits,
    mail,
    resolvedAuthHeaders,
  };
}
