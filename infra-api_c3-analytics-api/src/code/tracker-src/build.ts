// Bundles tracker-src/tracker.ts → tracker-dist/tracker.js at image build time.
// Runs as part of `npm ci && npx tsx tracker-src/build.ts` (see Dockerfile.native).
import { build } from 'esbuild';
import { mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = resolve(here, '../tracker-dist/tracker.js');

await mkdir(dirname(out), { recursive: true });

await build({
  entryPoints: [resolve(here, 'tracker.ts')],
  bundle: true,
  format: 'iife',
  target: ['es2018'],
  minify: true,
  sourcemap: false,
  outfile: out,
  legalComments: 'none',
  platform: 'browser',
});

console.log(`tracker bundled → ${out}`);
