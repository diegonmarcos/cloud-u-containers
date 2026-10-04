import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import multipart from '@fastify/multipart';
import { request as undiciRequest } from 'undici';
import { findSite, originAllowed } from '../lib/sites.js';
import { fanout } from '../lib/fanout.js';
import type { AppConfig } from '../config.js';

interface IngestQuery { sid?: string }

// /f — public file ingest. Accepts NDJSON (one event per line). Abuse model:
//   sid registered in build.json + Origin allowlisted + per-IP rate cap +
//   per-sid rate cap + body cap + per-line size cap + schema validation.
// No auth header — sid is public (it ships in tracker JS), so abuse-resistance
// is purely structural. Mirrors how matomo idsite + umami website-id work.
export async function registerIngest(app: FastifyInstance, cfg: AppConfig) {
  await app.register(multipart, {
    limits: {
      fileSize: cfg.limits.max_body_bytes,
      files: 1,
      fields: 4,
    },
  });

  const seenPerSid = new Map<string, { count: number; resetAt: number }>();

  function bumpSid(sid: string): boolean {
    const now = Date.now();
    const cur = seenPerSid.get(sid);
    if (!cur || cur.resetAt < now) {
      seenPerSid.set(sid, { count: 1, resetAt: now + 60_000 });
      return true;
    }
    cur.count += 1;
    return cur.count <= cfg.limits.rate_per_sid_per_min;
  }

  const handler = async (req: FastifyRequest, reply: FastifyReply) => {
    const q = req.query as IngestQuery;
    const sid = q.sid;
    if (!sid) return reply.code(400).send({ error: 'sid required' });

    const site = findSite(cfg, sid);
    if (!site) return reply.code(404).send({ error: 'unknown sid' });

    const origin = req.headers.origin as string | undefined;
    if (!originAllowed(site, origin)) {
      return reply.code(403).send({ error: 'origin not allowed' });
    }

    if (!bumpSid(sid)) {
      return reply.code(429).send({ error: 'sid rate limit exceeded' });
    }

    let bodyText: string;
    const ct = (req.headers['content-type'] ?? '').toString().toLowerCase();
    if (ct.startsWith('multipart/form-data')) {
      const file = await req.file();
      if (!file) return reply.code(400).send({ error: 'no file' });
      const buf = await file.toBuffer();
      bodyText = buf.toString('utf8');
    } else {
      // Other types: api/index.ts registers a '*' content-type parser with
      // parseAs:'buffer', so req.body is a Buffer (or undefined for empty).
      if (Buffer.isBuffer(req.body)) bodyText = req.body.toString('utf8');
      else if (typeof req.body === 'string') bodyText = req.body;
      else bodyText = '';
    }

    const lines = bodyText.split(/\r?\n/).filter((l) => l.length > 0);
    if (lines.length === 0) return reply.code(400).send({ error: 'empty body' });
    if (lines.length > cfg.limits.max_ingest_lines) {
      return reply.code(413).send({ error: 'too many lines', max: cfg.limits.max_ingest_lines });
    }

    const events: unknown[] = [];
    for (let i = 0; i < lines.length; i += 1) {
      try {
        events.push(JSON.parse(lines[i]));
      } catch {
        return reply.code(400).send({ error: 'invalid ndjson', line: i + 1 });
      }
    }

    const result = await fanout({
      events,
      site,
      cfg,
      ip: req.ip,
      ua: (req.headers['user-agent'] ?? '').toString(),
      doRequest: undiciRequest,
    });

    return reply.code(202).send({ accepted: events.length, results: result });
  };

  app.route({
    method: 'POST',
    url: '/f',
    config: {
      rateLimit: {
        max: cfg.limits.rate_per_ip_per_min,
        timeWindow: '1 minute',
      },
    },
    handler,
  });
}
