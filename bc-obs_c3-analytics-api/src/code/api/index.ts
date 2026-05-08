import Fastify from 'fastify';
import { loadConfig } from './config.js';
import { registerCors } from './plugins/cors.js';
import { registerRateLimit } from './plugins/ratelimit.js';
import { registerHealth } from './routes/health.js';
import { registerProxy } from './routes/proxy.js';
import { registerIngest } from './routes/ingest.js';
import { registerTracker } from './routes/tracker.js';

const cfg = loadConfig();

const app = Fastify({
  logger: { level: process.env.LOG_LEVEL ?? 'info' },
  bodyLimit: cfg.limits.max_body_bytes,
  trustProxy: true, // behind Caddy on gcp-proxy
  disableRequestLogging: false,
});

await registerCors(app, cfg);
await registerRateLimit(app, cfg);

// Pure passthrough requires the original bytes. Fastify's built-in JSON +
// text parsers are MORE specific than '*' and would otherwise reshape the
// body, leaving the proxy with nothing to forward. Strip the built-ins,
// then register a single '*' buffer parser. @fastify/multipart later
// registers its own multipart/form-data parser which is more specific and
// wins for that one type.
app.removeAllContentTypeParsers();
app.addContentTypeParser('*', { parseAs: 'buffer' }, (_req, body, done) => {
  done(null, body);
});

await app.register(async (scope) => {
  await registerHealth(scope);
  await registerTracker(scope, cfg);
  await registerProxy(scope, cfg);
  await registerIngest(scope, cfg);
}, { prefix: cfg.basePath });

const closeOn = ['SIGINT', 'SIGTERM'] as const;
for (const sig of closeOn) {
  process.on(sig, () => {
    app.log.info({ sig }, 'shutting down');
    app.close().then(() => process.exit(0));
  });
}

try {
  await app.listen({ host: cfg.host, port: cfg.port });
  app.log.info(
    { backends: Object.keys(cfg.backends), sites: cfg.sites.length },
    'c3-analytics-api ready',
  );
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
