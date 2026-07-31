import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { request as undiciRequest } from 'undici';
import type { AppConfig, BackendCfg } from '../config.js';

// Headers that must NOT pass through (hop-by-hop or invalid downstream).
const STRIP_REQ_HEADERS = new Set([
  'host', 'connection', 'keep-alive', 'transfer-encoding',
  'upgrade', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer',
  'content-length', // re-set by undici
]);

const STRIP_RES_HEADERS = new Set([
  'connection', 'keep-alive', 'transfer-encoding', 'upgrade',
  'proxy-authenticate', 'proxy-authorization', 'te', 'trailer',
]);

function copyReqHeaders(req: FastifyRequest, extra: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (v == null) continue;
    if (STRIP_REQ_HEADERS.has(k.toLowerCase())) continue;
    out[k] = Array.isArray(v) ? v.join(',') : String(v);
  }
  // Forward original client IP for matomo cip= equivalent / OO source.
  out['x-forwarded-for'] = req.ip;
  Object.assign(out, extra);
  return out;
}

function buildTargetUrl(cfg: BackendCfg, search: string): string {
  return cfg.url + (search ? (cfg.url.includes('?') ? '&' : '?') + search : '');
}

async function forward(
  req: FastifyRequest,
  reply: FastifyReply,
  cfg: AppConfig,
  slug: string,
) {
  const backend = cfg.backends[slug];
  if (!backend) return reply.code(404).send({ error: 'unknown backend' });
  if (!backend.methods.includes(req.method)) {
    return reply.code(405).send({ error: 'method not allowed' });
  }

  const extra: Record<string, string> = {};
  const auth = cfg.resolvedAuthHeaders[slug];
  if (auth) extra['authorization'] = auth;

  // Preserve query string from the inbound request (matomo uses GET pixels).
  const qIdx = req.url.indexOf('?');
  const search = qIdx >= 0 ? req.url.slice(qIdx + 1) : '';
  const target = buildTargetUrl(backend, search);

  try {
    // req.body is a Buffer because index.ts registers a '*' parser with
    // parseAs:'buffer'. For GET, body is undefined; for POST, the raw bytes
    // are forwarded unchanged so matomo / umami / oo see exactly what the
    // browser sent (passthrough invariant).
    const reqBody = req.method === 'GET'
      ? undefined
      : (Buffer.isBuffer(req.body) ? req.body : undefined);

    const upstream = await undiciRequest(target, {
      method: req.method as 'GET' | 'POST',
      headers: copyReqHeaders(req, extra),
      body: reqBody,
      headersTimeout: cfg.limits.request_timeout_ms,
      bodyTimeout: cfg.limits.request_timeout_ms,
    });

    reply.code(upstream.statusCode);
    for (const [k, v] of Object.entries(upstream.headers)) {
      if (v == null) continue;
      if (STRIP_RES_HEADERS.has(k.toLowerCase())) continue;
      reply.header(k, v as string | string[]);
    }
    return reply.send(upstream.body);
  } catch (err) {
    req.log.error({ err, slug, target }, 'proxy upstream error');
    return reply.code(502).send({ error: 'upstream unavailable', backend: backend.service });
  }
}

export async function registerProxy(app: FastifyInstance, cfg: AppConfig) {
  for (const slug of Object.keys(cfg.backends)) {
    const route = `/${slug}`;
    const handler = (req: FastifyRequest, reply: FastifyReply) => forward(req, reply, cfg, slug);
    app.route({
      method: ['GET', 'POST'],
      url: route,
      config: {
        rateLimit: {
          max: cfg.limits.rate_per_ip_per_min,
          timeWindow: '1 minute',
        },
      },
      handler,
    });
  }
}
