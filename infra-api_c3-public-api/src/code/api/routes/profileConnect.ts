// ── Profile ▸ Connect — bearer + mailed code → the decrypted profile bundle ──
//
// POST /profile/connect/start   → 202 {sent_to, expires_in}   (mails a code)
// POST /profile/connect/fetch   {code} → 200 {schema, bundle}
//   Public URLs: https://api.diegonmarcos.com/pub/profile/connect/{start,fetch}
//
// AUTH, two factors:
//   1. Caddy's mkProtected gate — /profile/* is not in public_paths[], so an
//      Authelia bearer is validated by introspect-proxy, which stamps
//      X-Auth-User. Unlike /superapp/*, this route ALSO refuses a request that
//      arrives without that header: mesh-IP trust is not enough for a file that
//      carries every personal secret (#360 — never anonymous).
//   2. The mailed code, bound to that X-Auth-User identity, single use.
//
// The code is delivered exactly the way /mail/http-to-smtp delivers: plain SMTP
// to maddy:25 over wg0 (build.json#mail.primary), to the owner mailbox declared
// in build.json#profile_connect.mail_to.
//
// Logic lives in shared/profile-connect.ts (zero imports, so the tester loads
// it directly); this file is only the HTTP shape.
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import nodemailer from "nodemailer";
import type { AppConfig } from "../../shared/config.js";
import {
  CodeStore,
  DecryptError,
  codeMail,
  identity,
  loadBundle,
  maskAddress,
  missingParts,
} from "../../shared/profile-connect.js";

export async function registerProfileConnect(app: FastifyInstance, cfg: AppConfig) {
  const pc = cfg.profileConnect;
  const codes = new CodeStore(pc);

  const gate = (req: FastifyRequest, reply: FastifyReply): string | null => {
    const user = identity(req.headers);
    if (!user) {
      reply.code(401).send({ error: "unauthorized", detail: "no bearer identity (X-Auth-User) — call through api.diegonmarcos.com/pub with an Authelia bearer" });
      return null;
    }
    const missing = missingParts(pc);
    if (missing.length) {
      req.log.warn({ missing }, "profile_connect.not_configured");
      reply.code(503).send({ error: "not_configured", missing });
      return null;
    }
    reply.header("Cache-Control", "no-store");
    return user;
  };

  app.post("/profile/connect/start", async (req, reply) => {
    const user = gate(req, reply);
    if (!user) return reply;

    const issued = codes.issue(user, Date.now());
    if (!issued.ok) {
      return reply.code(429).header("Retry-After", String(issued.retryAfter))
        .send({ error: issued.error, retry_after: issued.retryAfter });
    }

    const transport = nodemailer.createTransport({
      host: cfg.mail.primary.host,
      port: cfg.mail.primary.port,
      secure: false,
      ignoreTLS: cfg.mail.primary.port === 25,
      requireTLS: false,
      name: cfg.mail.heloDomain,
      connectionTimeout: cfg.limits.request_timeout_ms,
      greetingTimeout: cfg.limits.request_timeout_ms,
      socketTimeout: cfg.limits.request_timeout_ms,
    });
    try {
      await transport.sendMail({
        envelope: { from: pc.mailFrom, to: [pc.mailTo] },
        raw: codeMail(pc, issued.code, user, new Date()),
      });
    } catch (err) {
      // A code nobody received must not stay live and block a retry behind the
      // cooldown.
      codes.revoke(user);
      req.log.error({ err: (err as Error).message }, "profile_connect.mail_failed");
      return reply.code(502).send({ error: "mail_failed" });
    } finally {
      transport.close();
    }
    req.log.info({ user }, "profile_connect.code_sent");
    return reply.code(202).send({ sent_to: maskAddress(pc.mailTo), expires_in: issued.expiresIn });
  });

  app.post<{ Body: { code?: unknown } }>("/profile/connect/fetch", async (req, reply) => {
    const user = gate(req, reply);
    if (!user) return reply;

    const code = typeof req.body?.code === "string" ? req.body.code : "";
    const v = codes.verify(user, code, Date.now());
    if (!v.ok) {
      if (v.error === "too_many_attempts") return reply.code(429).send({ error: v.error });
      return reply.code(403).send(v.error === "bad_code"
        ? { error: v.error, attempts_left: v.attemptsLeft }
        : { error: v.error });
    }

    try {
      const out = loadBundle(pc);
      req.log.info({ user }, "profile_connect.bundle_served");
      return reply.code(200).type("application/json").send(out);
    } catch (e) {
      if (e instanceof DecryptError) {
        req.log.error({ err: e.message }, "profile_connect.decrypt_failed");
        return reply.code(502).send({ error: "decrypt_failed" });
      }
      throw e;
    }
  });
}
