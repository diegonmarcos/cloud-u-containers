import type { FastifyInstance } from "fastify";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

// Unauthenticated ingest for client-side log dumps (e.g. galaxy-earth's
// "Log Export" button) — see auth.ts isPublicPath() for the /public/ allowlist.
const LOGS_DIR = process.env.PUBLIC_LOGS_DIR ?? "/app/public/logs";
const MAX_LOG_BYTES = 2 * 1024 * 1024; // 2MB — plenty for a browser console dump

export async function registerPublicLogsRoutes(app: FastifyInstance) {
  app.post("/public/logs", async (req, reply) => {
    const body = req.body as { source?: string; log?: string } | undefined;
    if (!body?.log || typeof body.log !== "string") {
      return reply.code(400).send({ error: "missing 'log' field" });
    }
    if (body.log.length > MAX_LOG_BYTES) {
      return reply.code(413).send({ error: "log too large" });
    }
    const safeSource = (body.source ?? "client").replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 60);
    const filename = `${safeSource}-${Date.now()}.log`;
    await mkdir(LOGS_DIR, { recursive: true });
    await writeFile(join(LOGS_DIR, filename), body.log, "utf8");
    req.log.info({ filename, bytes: body.log.length }, "public log received");
    return { ok: true, file: filename };
  });
}
