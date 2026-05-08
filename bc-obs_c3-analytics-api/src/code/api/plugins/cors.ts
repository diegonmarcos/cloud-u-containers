import type { FastifyInstance } from 'fastify';
import cors from '@fastify/cors';
import type { AppConfig } from '../config.js';

// Reflective CORS: only echo Origin if it appears in any registered site's
// origins[]. Wildcard '*' is never used because credentials may be needed for
// some backends (matomo cookies). Pure passthrough — no Origin → no CORS headers.
export async function registerCors(app: FastifyInstance, cfg: AppConfig) {
  const allOrigins = new Set<string>();
  for (const s of cfg.sites) for (const o of s.origins) allOrigins.add(o);

  await app.register(cors, {
    origin: (origin, cb) => {
      if (!origin) return cb(null, false);
      cb(null, allOrigins.has(origin));
    },
    credentials: true,
    methods: ['GET', 'POST', 'OPTIONS'],
    maxAge: 600,
  });
}
