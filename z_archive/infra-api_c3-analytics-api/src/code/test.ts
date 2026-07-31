// Smoke test — boots three mock upstreams and the API, exercises every public
// endpoint, asserts. Uses only Node built-ins + spawned api child. Pure local;
// does not touch real matomo/umami/openobserve.
import { createServer, type IncomingMessage, type ServerResponse, type Server } from 'node:http';
import { spawn } from 'node:child_process';
import { setTimeout as wait } from 'node:timers/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

interface MockHit { method: string; url: string; headers: NodeJS.Dict<string | string[]>; body: string }
const hits: Record<'matomo' | 'umami' | 'oo', MockHit[]> = { matomo: [], umami: [], oo: [] };

function startMock(port: number, name: keyof typeof hits): Promise<Server> {
  return new Promise((res) => {
    const srv = createServer((req: IncomingMessage, resp: ServerResponse) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        hits[name].push({ method: req.method ?? '?', url: req.url ?? '', headers: req.headers, body });
        resp.statusCode = 200;
        resp.setHeader('content-type', 'application/json');
        resp.end(JSON.stringify({ ok: true, by: name }));
      });
    });
    srv.listen(port, '127.0.0.1', () => res(srv));
  });
}

let pass = 0;
let fail = 0;
function check(name: string, cond: boolean, detail = '') {
  if (cond) { pass += 1; console.log(`  ✓ ${name}`); }
  else { fail += 1; console.log(`  ✗ ${name} ${detail}`); }
}

async function waitForHealth(url: string, attempts = 60): Promise<boolean> {
  for (let i = 0; i < attempts; i += 1) {
    try {
      const r = await fetch(url);
      if (r.ok) return true;
    } catch { /* api not ready */ }
    await wait(250);
  }
  return false;
}

async function main(): Promise<void> {
  const ports = { matomo: 18101, umami: 18102, oo: 18103, api: 18100 };

  const m = await startMock(ports.matomo, 'matomo');
  const u = await startMock(ports.umami, 'umami');
  const o = await startMock(ports.oo, 'oo');

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    HOST: '127.0.0.1',
    PORT: String(ports.api),
    BASE_PATH: '/c3a',
    LOG_LEVEL: 'warn',
    OPENOBSERVE_AUTHORIZATION: 'Basic dGVzdDp0ZXN0',
    BACKENDS_JSON: JSON.stringify({
      e: { url: `http://127.0.0.1:${ports.matomo}/matomo.php`,           service: 'matomo',      methods: ['GET', 'POST'], auth_header_env: null },
      s: { url: `http://127.0.0.1:${ports.umami}/api/send`,              service: 'umami',       methods: ['POST'],         auth_header_env: null },
      l: { url: `http://127.0.0.1:${ports.oo}/api/default/default/_json`, service: 'openobserve', methods: ['POST'],         auth_header_env: 'OPENOBSERVE_AUTHORIZATION' },
    }),
    SITES_JSON: JSON.stringify([
      { id: 'test-sid', origins: ['http://localhost:3001'], matomo_idsite: 1, umami_website_id: '00000000-0000-0000-0000-000000000000', openobserve_stream: 'test' },
    ]),
    LIMITS_JSON: JSON.stringify({
      max_body_bytes: 1048576, max_ingest_lines: 5000,
      rate_per_ip_per_min: 10000, rate_per_sid_per_min: 10000,
      tracker_cache_seconds: 60, request_timeout_ms: 5000,
    }),
  };

  const api = spawn('npx', ['tsx', resolve(here, 'api/index.ts')], {
    env,
    stdio: ['ignore', 'inherit', 'inherit'],
    detached: true,
  });

  const cleanup = () => {
    try { if (api.pid) process.kill(-api.pid, 'SIGTERM'); } catch { /* gone */ }
    m.close(); u.close(); o.close();
  };
  process.on('exit', cleanup);

  const base = `http://127.0.0.1:${ports.api}/c3a`;

  if (!(await waitForHealth(`${base}/healthz`))) {
    console.error('api never reported healthy');
    cleanup();
    process.exit(2);
  }

  // ── /healthz ──────────────────────────────────────────────
  {
    const r = await fetch(`${base}/healthz`);
    const j = await r.json() as { ok?: boolean };
    check('GET /healthz → 200 + {ok:true}', r.status === 200 && j.ok === true);
  }

  // ── /t.js ──────────────────────────────────────────────────
  {
    const r = await fetch(`${base}/t.js`);
    const ct = r.headers.get('content-type') ?? '';
    const txt = await r.text();
    check('GET /t.js → 200', r.status === 200);
    check('GET /t.js content-type is JS', ct.includes('javascript'));
    check('GET /t.js has runtime config preamble', txt.includes('window.__c3a_config__'));
    check('GET /t.js exposes registered sid', txt.includes('test-sid'));
    check('GET /t.js bundle ships c3a global', txt.includes('window.c3a'));
  }

  // ── /e (matomo) GET pixel passthrough ──────────────────────
  {
    const r = await fetch(`${base}/e?idsite=1&rec=1&url=https%3A%2F%2Fexample.com`);
    check('GET /e → 200 (matomo pixel)', r.status === 200);
    check('matomo upstream received GET',
      hits.matomo.length === 1 && hits.matomo[0].method === 'GET');
    check('matomo upstream got x-forwarded-for',
      typeof hits.matomo[0]?.headers['x-forwarded-for'] === 'string');
    check('matomo upstream did NOT receive Authorization header',
      !hits.matomo[0]?.headers.authorization);
    check('matomo upstream URL preserved query string',
      (hits.matomo[0]?.url ?? '').includes('idsite=1'));
  }

  // ── /s (umami) POST passthrough ────────────────────────────
  {
    const r = await fetch(`${base}/s`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'event', payload: { name: 'click' } }),
    });
    check('POST /s → 200 (umami)', r.status === 200);
    check('umami upstream received POST',
      hits.umami.length === 1 && hits.umami[0].method === 'POST');
    check('umami upstream body preserved',
      JSON.parse(hits.umami[0]?.body ?? '{}').payload?.name === 'click');
  }

  // ── /l (openobserve) POST + auth header injection ──────────
  {
    const r = await fetch(`${base}/l`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify([{ a: 1 }]),
    });
    check('POST /l → 200 (openobserve)', r.status === 200);
    check('openobserve upstream got injected Authorization',
      hits.oo[0]?.headers.authorization === 'Basic dGVzdDp0ZXN0');
  }

  // ── method enforcement ─────────────────────────────────────
  {
    const r = await fetch(`${base}/s`, { method: 'GET' });
    check('GET /s → 405 (umami POST-only)', r.status === 405);
  }

  // ── /f validation matrix ───────────────────────────────────
  {
    const r = await fetch(`${base}/f`, {
      method: 'POST', headers: { 'content-type': 'application/x-ndjson' },
      body: '{"event":"x"}\n',
    });
    check('POST /f without sid → 400', r.status === 400);
  }
  {
    const r = await fetch(`${base}/f?sid=does-not-exist`, {
      method: 'POST', headers: { 'content-type': 'application/x-ndjson' },
      body: '{"event":"x"}\n',
    });
    check('POST /f unknown sid → 404', r.status === 404);
  }
  {
    const r = await fetch(`${base}/f?sid=test-sid`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-ndjson', origin: 'https://evil.example' },
      body: '{"event":"x"}\n',
    });
    check('POST /f wrong origin → 403', r.status === 403);
  }

  // ── /f happy path: fan-out to all three upstreams ──────────
  {
    const before = { m: hits.matomo.length, u: hits.umami.length, o: hits.oo.length };
    const r = await fetch(`${base}/f?sid=test-sid`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-ndjson', origin: 'http://localhost:3001' },
      body: '{"event":"a","url":"/x"}\n{"event":"b","url":"/y"}\n',
    });
    const j = await r.json() as { accepted?: number };
    check('POST /f valid → 202', r.status === 202);
    check('POST /f reports 2 events accepted', j.accepted === 2);
    await wait(300); // let fan-out settle
    check('fanout → matomo received hits', hits.matomo.length > before.m);
    check('fanout → umami received hits',  hits.umami.length  > before.u);
    check('fanout → openobserve received hits', hits.oo.length > before.o);
    const lastOo = hits.oo[hits.oo.length - 1];
    check('fanout → openobserve still gets auth header',
      lastOo?.headers.authorization === 'Basic dGVzdDp0ZXN0');
  }

  // ── /f payload caps ────────────────────────────────────────
  {
    const tooMany = Array.from({ length: 5001 }, () => '{"event":"x"}').join('\n');
    const r = await fetch(`${base}/f?sid=test-sid`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-ndjson', origin: 'http://localhost:3001' },
      body: tooMany,
    });
    check('POST /f over max_ingest_lines → 413', r.status === 413);
  }
  {
    const r = await fetch(`${base}/f?sid=test-sid`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-ndjson', origin: 'http://localhost:3001' },
      body: 'not-json\n',
    });
    check('POST /f invalid ndjson → 400', r.status === 400);
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  cleanup();
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((err) => { console.error(err); process.exit(2); });
