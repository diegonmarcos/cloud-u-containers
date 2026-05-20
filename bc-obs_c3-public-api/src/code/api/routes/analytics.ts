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

    // @fastify/http-proxy ALWAYS calls addContentTypeParser('application/json', ...)
    // (index.js:545) unless proxyPayloads:false. Fastify ships a default JSON
    // parser at root, so the plugin throws FST_ERR_CTP_ALREADY_PRESENT on the
    // 1st registration in any scope that inherits root parsers. Pass-through
    // analytics doesn't need body parsing — the proxy streams the raw body —
    // so disabling proxyPayloads is both correct and lets us mount N proxies.
    await app.register(httpProxy, {
      upstream,
      prefix: `/analytics/${slug}`,
      rewritePrefix: "",
      http2: false,
      proxyPayloads: false,
      replyOptions: {
        rewriteRequestHeaders: (_req, headers) => {
          const out: Record<string, string | string[]> = { ...headers } as Record<string, string | string[]>;
          if (authHeader) out["authorization"] = authHeader;
          return out;
        },
      },
    });

    app.log.info({ slug, upstream, methods: backend.methods }, "analytics.backend.registered");
  }
}
