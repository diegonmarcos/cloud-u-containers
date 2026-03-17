import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import fp from "fastify-plugin";

const PUBLIC_PATHS = new Set([
  "/health",
  "/docs",
  "/docs/",
  "/docs/json",
  "/docs/yaml",
]);

function isPublicPath(url: string): boolean {
  if (url.startsWith("/docs")) return true;
  return PUBLIC_PATHS.has(url);
}

function isMeshRequest(req: FastifyRequest): boolean {
  const ip = req.ip;
  // 10.0.0.x = WireGuard mesh, 172.x = Docker bridge (host/other VMs via WG)
  return ip.startsWith("10.0.0.") || ip.startsWith("172.") || ip === "127.0.0.1" || ip === "::1";
}

function isCaddyAuthenticated(req: FastifyRequest): boolean {
  // Bearer path: introspect-proxy sets X-Auth-User
  // Cookie path: Authelia forward_auth sets Remote-User
  return !!(req.headers["x-auth-user"] || req.headers["remote-user"]);
}

async function authHook(req: FastifyRequest, reply: FastifyReply) {
  // Public endpoints: no auth
  if (isPublicPath(req.url)) return;

  // WireGuard mesh: trusted
  if (isMeshRequest(req)) return;

  // Caddy already validated via introspect-proxy or Authelia
  if (isCaddyAuthenticated(req)) return;

  req.log.warn({
    url: req.url,
    ip: req.ip,
    hasXAuthUser: !!req.headers["x-auth-user"],
    hasRemoteUser: !!req.headers["remote-user"],
    headers: Object.keys(req.headers),
  }, "AUTH REJECTED — 401");
  reply.code(401).send({ error: "Unauthorized — use bearer token via Caddy" });
}

async function authPluginFn(app: FastifyInstance) {
  app.addHook("onRequest", authHook);
}

export const authPlugin = fp(authPluginFn, { name: "auth" });
