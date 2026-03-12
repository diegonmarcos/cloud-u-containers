import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import fp from "fastify-plugin";

const PUBLIC_PATHS = new Set([
  "/health",
  "/dash",
  "/docs",
  "/docs/",
  "/docs/json",
  "/docs/yaml",
]);

function isPublicPath(url: string): boolean {
  if (url.startsWith("/docs")) return true;
  if (url.startsWith("/dash")) return true;
  return PUBLIC_PATHS.has(url);
}

function isMeshRequest(req: FastifyRequest): boolean {
  const ip = req.ip;
  return ip.startsWith("10.0.0.") || ip === "127.0.0.1" || ip === "::1";
}

function isCaddyAuthenticated(req: FastifyRequest): boolean {
  // Caddy's introspect-proxy sets X-Auth-User on successful JWT validation
  return !!req.headers["x-auth-user"];
}

async function authHook(req: FastifyRequest, reply: FastifyReply) {
  // Public endpoints: no auth
  if (isPublicPath(req.url)) return;

  // WireGuard mesh: trusted
  if (isMeshRequest(req)) return;

  // Caddy already validated the JWT via introspect-proxy
  if (isCaddyAuthenticated(req)) return;

  reply.code(401).send({ error: "Unauthorized — use bearer token via Caddy" });
}

async function authPluginFn(app: FastifyInstance) {
  app.addHook("onRequest", authHook);
}

export const authPlugin = fp(authPluginFn, { name: "auth" });
