import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import fp from "fastify-plugin";
import { getBearerToken } from "../../shared/http.js";

const PUBLIC_PATHS = new Set([
  "/health",
  "/docs",
  "/docs/",
  "/docs/json",
  "/docs/yaml",
]);

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

  // Bearer token validation (defense-in-depth — Caddy+introspect-proxy handles primary auth)
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith("Bearer ")) {
    reply.code(401).send({ error: "Missing bearer token" });
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
