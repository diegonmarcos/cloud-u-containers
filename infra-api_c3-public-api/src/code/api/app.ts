// App factory for c3-public-api.
// Routes are mounted at the root (no base prefix) — Caddy's handle_path
// /c3-public-api/* strips the public prefix before forwarding, same pattern
// as c3-infra-api.
import Fastify, { type FastifyInstance } from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import { loadConfig, type AppConfig } from "../shared/config.js";
import { errorHandler } from "./plugins/error-handler.js";
import { registerHealth } from "./routes/health.js";
import { registerAnalytics } from "./routes/analytics.js";
import { registerMail } from "./routes/mail.js";

export async function buildApp(): Promise<{ app: FastifyInstance; cfg: AppConfig }> {
  const cfg = loadConfig();

  const app = Fastify({
    logger: { level: process.env.LOG_LEVEL ?? "info" },
    trustProxy: true, // behind Caddy
    bodyLimit: cfg.limits.max_body_bytes,
    disableRequestLogging: false,
  });

  // Public endpoints + analytics passthrough need raw bytes preserved.
  // Mail route uses the same raw stream (or accepts a JSON wrapper). One
  // catch-all '*' buffer parser keeps both paths happy.
  app.removeAllContentTypeParsers();
  app.addContentTypeParser("application/json", { parseAs: "string" }, (_req, body, done) => {
    try {
      done(null, body.length ? JSON.parse(body as string) : {});
    } catch (e) {
      done(e as Error, undefined);
    }
  });
  app.addContentTypeParser("*", { parseAs: "buffer" }, (_req, body, done) => {
    done(null, body);
  });

  await app.register(cors, { origin: true, credentials: true });
  await app.register(rateLimit, {
    max: cfg.limits.rate_per_ip_per_min,
    timeWindow: "1 minute",
    // Health endpoints excluded from rate limiting.
    //
    // Inbound mail delivery is excluded too, and that exclusion is load-bearing.
    // Every message the Cloudflare Email Worker mirrors to the mesh arrives here,
    // and it arrives from Cloudflare's egress IPs — a handful of addresses shared
    // by ALL inbound mail. A per-IP budget therefore is not "60 messages per
    // sender per minute", it is 60 messages per minute for the entire domain.
    // Any burst above that (a mailing-list digest, a newsletter fan-out, a busy
    // morning) gets 429'd, and once the worker's retries are spent the message is
    // gone from the self-hosted mirror for good. Real 429s on this path have been
    // observed in the gcp-proxy Caddy log.
    //
    // Dropping mail is a far worse outcome than the abuse this limit guards
    // against, and the route is not an open door: it sits behind Caddy's
    // forward_auth bearer check AND the app-layer X-API-Key in mail.ts.
    // Matched on the path suffix rather than an exact string: this app is
    // reached through Caddy at /pub/mail/http-to-smtp and mounts the route at
    // /mail/http-to-smtp, so whether the /pub prefix is stripped upstream
    // decides which one arrives. An exact match on the wrong one would silently
    // fail open and keep rate-limiting mail while looking fixed.
    allowList: (req) => {
      const path = (req.url || "").split("?")[0];
      return (
        path === "/health" ||
        path === "/ready" ||
        path.endsWith("/mail/http-to-smtp")
      );
    },
  });

  app.setErrorHandler(errorHandler);

  // Public, no auth — must be registered BEFORE any auth-bearing scopes
  // since fastify-plugin scoping is positional.
  await app.register(registerHealth);
  await registerAnalytics(app, cfg);

  // Bearer-gated — auth plugin is registered inside this scope.
  await registerMail(app, cfg);

  return { app, cfg };
}
