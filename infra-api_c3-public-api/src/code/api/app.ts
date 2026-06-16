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
    allowList: (req) => req.url === "/health" || req.url === "/ready",
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
