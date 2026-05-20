// /analytics/* — public, no auth, rate-limited.
// Reverse-proxies to first-party analytics backends using @fastify/http-proxy.
//
// Routes are derived from build.json#backends + cloud-data IP/port lookup
// done at build-time in compose.nix (BACKENDS_JSON env var). Nothing here is
// hardcoded: a new backend slug in build.json automatically gets a mount
// at /analytics/<slug>/*.
//
// Same backends as the legacy c3-analytics-api on gcp-proxy (matomo, umami,
// openobserve) so swapping the public CNAME is a one-touch migration.
import type { FastifyInstance } from "fastify";
import httpProxy from "@fastify/http-proxy";
import type { AppConfig } from "../../shared/config.js";

export async function registerAnalytics(app: FastifyInstance, cfg: AppConfig) {
  for (const [slug, backend] of Object.entries(cfg.backends)) {
    const upstream = backend.url; // already includes rewrite_path
    const authHeader = cfg.resolvedAuthHeaders[slug];

    // Each httpProxy plugin tries to install Fastify's JSON content-type
    // parser into its enclosing scope. Registering N proxies on the SAME
    // scope throws FST_ERR_CTP_ALREADY_PRESENT on the 2nd. Fix: encapsulate
    // every proxy in its OWN nested Fastify scope — the parser tree is
    // per-scope so each gets a clean slate. @fastify/http-proxy README's
    // "multiple proxies" example uses exactly this pattern.
    await app.register(async (instance) => {
      await instance.register(httpProxy, {
        upstream,
        prefix: `/analytics/${slug}`,
        rewritePrefix: "",
        http2: false,
        // Same-origin proxy: do NOT replace Host header (we want the backend
        // to see its own canonical host so e.g. Matomo computes URLs right).
        replyOptions: {
          rewriteRequestHeaders: (_req, headers) => {
            const out: Record<string, string | string[]> = { ...headers } as Record<string, string | string[]>;
            if (authHeader) out["authorization"] = authHeader;
            return out;
          },
        },
      });
    });

    app.log.info({ slug, upstream, methods: backend.methods }, "analytics.backend.registered");
  }
}
