// Authelia Bearer enforcement — applied ONLY to /mail/* routes.
// /analytics/* and /health, /ready are public and bypass this plugin.
//
// Mirrors c3-infra-api/src/code/api/plugins/auth.ts but scoped to a single
// route prefix via `addHook` inside a fastify scope (see app.ts), rather than
// app-wide. Caddy's introspect-proxy validates the JWT upstream and stamps
// X-Auth-User on success.
import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import fp from "fastify-plugin";

function isMeshRequest(req: FastifyRequest): boolean {
  const ip = req.ip;
  // 10.0.0.x = wg0 mesh, 172.x = Docker bridge (host-network sees other
  // containers' bridge IPs), localhost = same-host curl.
  return (
    ip.startsWith("10.0.0.") ||
    ip.startsWith("10.1.0.") ||
    ip.startsWith("172.") ||
    ip === "127.0.0.1" ||
    ip === "::1"
  );
}

function isCaddyAuthenticated(req: FastifyRequest): boolean {
  // Bearer path: introspect-proxy sets X-Auth-User
  // Cookie path: Authelia forward_auth sets Remote-User
  return !!(req.headers["x-auth-user"] || req.headers["remote-user"]);
}

async function authHook(req: FastifyRequest, reply: FastifyReply) {
  if (isMeshRequest(req)) return;
  if (isCaddyAuthenticated(req)) return;

  req.log.warn(
    {
      url: req.url,
      ip: req.ip,
      hasXAuthUser: !!req.headers["x-auth-user"],
      hasRemoteUser: !!req.headers["remote-user"],
    },
    "AUTH REJECTED — 401",
  );
  reply.code(401).send({ error: "Unauthorized — Bearer token required (verified by Caddy/introspect-proxy)" });
}

async function authPluginFn(app: FastifyInstance) {
  app.addHook("onRequest", authHook);
}

export const authPlugin = fp(authPluginFn, { name: "c3-public-api-auth" });
