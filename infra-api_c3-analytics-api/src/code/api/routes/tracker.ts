import type { FastifyInstance } from 'fastify';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import type { AppConfig } from '../config.js';

// Serves the prebuilt tracker bundle. The bundle is built once at image-build
// time by tracker-src/build.ts → tracker-dist/tracker.js. We slap a header
// preamble that exposes the runtime base path + sites map so the same bundle
// is reusable across deployments without a rebuild.
export async function registerTracker(app: FastifyInstance, cfg: AppConfig) {
  const here = dirname(fileURLToPath(import.meta.url));
  const bundlePath = resolve(here, '../../tracker-dist/tracker.js');

  let bundle = '';
  try {
    bundle = await readFile(bundlePath, 'utf8');
  } catch (err) {
    app.log.warn({ err, bundlePath }, 'tracker bundle missing — /t.js will return a stub');
    bundle = '/* tracker bundle missing — run `tsx tracker-src/build.ts` */';
  }

  const cacheSeconds = cfg.limits.tracker_cache_seconds;

  app.get('/t.js', async (_req, reply) => {
    reply
      .header('content-type', 'application/javascript; charset=utf-8')
      .header('cache-control', `public, max-age=${cacheSeconds}`)
      .header('x-content-type-options', 'nosniff');

    const preamble =
      `window.__c3a_config__ = ${JSON.stringify({
        basePath: cfg.basePath,
        sites: cfg.sites.map((s) => ({
          id: s.id,
          matomo_idsite: s.matomo_idsite ?? null,
          umami_website_id: s.umami_website_id ?? null,
          openobserve_stream: s.openobserve_stream ?? null,
        })),
      })};\n`;

    return preamble + bundle;
  });
}
