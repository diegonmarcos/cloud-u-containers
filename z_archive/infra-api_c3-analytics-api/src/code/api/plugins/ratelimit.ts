import type { FastifyInstance } from 'fastify';
import rateLimit from '@fastify/rate-limit';
import type { AppConfig } from '../config.js';

// Two-tier rate limit:
//   1) per-IP global cap (cheap, in-memory) — caps abusive clients
//   2) per-sid cap is enforced inside /f route handler since sid is
//      payload-derived. /f keyGenerator combines sid+IP for proper bucketing.
export async function registerRateLimit(app: FastifyInstance, cfg: AppConfig) {
  await app.register(rateLimit, {
    global: false, // opt-in per route
    max: cfg.limits.rate_per_ip_per_min,
    timeWindow: '1 minute',
    cache: 10000,
    allowList: [], // none — even local must obey
    keyGenerator: (req) => req.ip,
    addHeadersOnExceeding: { 'x-ratelimit-limit': true, 'x-ratelimit-remaining': true },
    addHeaders: { 'x-ratelimit-limit': true, 'x-ratelimit-remaining': true, 'retry-after': true },
  });
}
