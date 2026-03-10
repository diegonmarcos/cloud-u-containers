import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import fp from "fastify-plugin";
import { getBearerToken } from "../../shared/http.js";

const PUBLIC_PATHS = new Set([
  "/health",
  "/dash",
  "/docs",
  "/docs/",
  "/docs/json",
  "/docs/yaml",
]);

// Paths that accept X-API-Key header (static token for external services like CF Workers)
function isApiKeyPath(url: string): boolean {
  return url.startsWith("/up/") || (url.startsWith("/health/") && !url.startsWith("/health/tier") && !url.startsWith("/health/deployed") && !url.startsWith("/health/drift") && !url.startsWith("/health/status") && !url.startsWith("/health/declared"));
}

function getApiKey(): string | null {
  return process.env.C3_API_KEY || null;
}

function isPublicPath(url: string): boolean {
  // Swagger UI assets
  if (url.startsWith("/docs")) return true;
  return PUBLIC_PATHS.has(url);
}

function isMeshRequest(req: FastifyRequest): boolean {
  const ip = req.ip;
  // WireGuard mesh: 10.0.0.x or localhost
  return ip.startsWith("10.0.0.") || ip === "127.0.0.1" || ip === "::1";
}

async function authHook(req: FastifyRequest, reply: FastifyReply) {
  // Public endpoints: no auth
  if (isPublicPath(req.url)) return;

  // WireGuard mesh: trusted
  if (isMeshRequest(req)) return;

  // API key auth for /up/ and /health/:target (external services like CF Workers)
  if (isApiKeyPath(req.url)) {
    const apiKey = req.headers["x-api-key"] as string | undefined;
    const validKey = getApiKey();
    if (validKey && apiKey === validKey) return;
    // Fall through to bearer token check
  }

  // Bearer token validation (defense-in-depth — Caddy+introspect-proxy handles primary auth)
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith("Bearer ")) {
    reply.code(401).send({ error: "Missing bearer token or API key" });
    return;
  }

  const token = authHeader.slice(7);
  const validToken = getBearerToken();

  if (!validToken || token !== validToken) {
    reply.code(403).send({ error: "Invalid bearer token" });
    return;
  }
}

async function authPluginFn(app: FastifyInstance) {
  app.addHook("onRequest", authHook);
}

export const authPlugin = fp(authPluginFn, { name: "auth" });
