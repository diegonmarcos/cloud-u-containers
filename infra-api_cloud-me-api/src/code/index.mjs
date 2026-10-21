#!/usr/bin/env node
// cloud-me-api — read-only, authenticated read path to the owner's private
// cloud-me-* repos (#1079).
//
//   fleet app ──Authelia bearer/session──> Caddy (forward_auth) ──> here
//                                                                    │ read-only deploy key per repo (sops env_file)
//                                                                    v
//                                                       shallow clone on tmpfs ──> declared datasets / filtered files
//
// No app holds a GitHub credential. Nothing here can write: only `git clone`
// and `git fetch` run, over per-repo read-only deploy keys. Stdlib only.

import { createServer } from 'node:http';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { decideAuth, decideSession } from './authz.mjs';
import { loadRuntime } from './contract.mjs';
import { buildTable, match } from './router.mjs';
import { createStore, redactSecrets } from './store.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

function findBuildJson() {
  const candidates = [process.env.BUILD_JSON_PATH, join(HERE, 'build.json'), join(HERE, '..', '..', 'build.json')].filter(Boolean);
  const hit = candidates.find((p) => existsSync(p));
  if (!hit) throw new Error(`build.json not found; looked at ${candidates.join(', ')}`);
  return hit;
}

const RT = loadRuntime(findBuildJson());

// build.json is the DECLARATION; env overrides exist only so the tester can
// point the outbound dependencies at local stubs. Nothing in production sets them.
const AUTH = { ...RT.authelia, jwks_url: process.env.JWKS_URL || RT.authelia.jwks_url, issuer: process.env.ISSUER || RT.authelia.issuer };
const SESSION = { ...RT.authelia.session, verify_url: process.env.AUTHELIA_VERIFY_URL || RT.authelia.session.verify_url };
const PORT = Number(process.env.PORT || 8124);
const HOST = process.env.BIND_HOST || '0.0.0.0';
const DATA_DIR = process.env.CME_DATA_DIR || '/data';
const KEY_DIR = process.env.CME_KEY_DIR || '/run/keys';
const URL_OVERRIDE_DIR = process.env.CME_URL_OVERRIDE_DIR || ''; // tester only: local bare repos instead of GitHub

const STORE = createStore({
  repos: RT.repos.list,
  files: RT.files,
  dataDir: DATA_DIR,
  keyDir: KEY_DIR,
  env: process.env,
  knownHosts: RT.repos.known_hosts,
  gitTimeoutMs: RT.repos.git_timeout_ms,
  urlFor: (r) => (URL_OVERRIDE_DIR ? `${URL_OVERRIDE_DIR}/${r.name}` : r.ssh),
});

// ── Authelia bearer verification (RS256 over Authelia's JWKS) ──────────────
// Mirrors infra-sec_introspect-proxy's checks exactly — same jwks_url, issuer
// and required scope — so a token minted for ANY existing Authelia client (cli,
// cloud-admin, claude-*) works here with no new OIDC client and no new grant.
let jwksCache = { keys: null, at: 0 };

async function fetchJwks() {
  if (jwksCache.keys && (Date.now() - jwksCache.at) / 1000 < AUTH.jwks_cache_ttl_s) {
    return jwksCache.keys;
  }
  try {
    const res = await fetch(AUTH.jwks_url, {
      signal: AbortSignal.timeout(AUTH.jwks_fetch_timeout_ms),
    });
    if (!res.ok) throw new Error(`jwks http ${res.status}`);
    const body = await res.json();
    jwksCache = { keys: body.keys || [], at: Date.now() };
    return jwksCache.keys;
  } catch {
    // Serve the last-known-good key set rather than force a refetch on every
    // request while Authelia is unreachable — the exact failure mode that took
    // introspect-proxy's bearer auth down on 2026-08-22.
    if (jwksCache.keys) return jwksCache.keys;
    const e = new Error('jwks unavailable');
    e.code = 'jwks_unavailable';
    throw e;
  }
}

const b64uToBuf = (s) => Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const b64uToJson = (s) => JSON.parse(b64uToBuf(s).toString('utf8'));

async function verifyAutheliaBearer(token) {
  const parts = token.split('.');
  if (parts.length !== 3) throw new Error('not a compact JWS');
  const [h, p, s] = parts;

  const header = b64uToJson(h);
  if (header.alg !== 'RS256') throw new Error(`unsupported alg ${header.alg}`);

  const keys = await fetchJwks();
  const jwk = keys.find((k) => k.kid === header.kid) || (keys.length === 1 ? keys[0] : null);
  if (!jwk) throw new Error(`no JWKS key for kid ${header.kid}`);

  const key = await crypto.subtle.importKey(
    'jwk',
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5', key, b64uToBuf(s), Buffer.from(`${h}.${p}`, 'utf8'),
  );
  if (!ok) throw new Error('signature does not verify');

  const claims = b64uToJson(p);
  if (claims.iss !== AUTH.issuer) throw new Error(`bad issuer ${claims.iss}`);
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp === 'number' && claims.exp <= now) throw new Error('expired');
  if (typeof claims.nbf === 'number' && claims.nbf > now + 60) throw new Error('not yet valid');
  return claims;
}

// ── Authelia session verification (the cookie path) ────────────────────────
// Asks Authelia's auth-request endpoint the question the edge's forward_auth
// asks: is this cookie a live session its access rules admit for this URL?
// auth-request reads X-Original-URL, which the hub's auth vhost passes through
// untouched (forward-auth reads X-Forwarded-Host, which that proxy rewrites to
// auth.* — the wrong rule). Never cached: a logout must take effect at once.
async function verifyAutheliaSession(cookie, method, path) {
  let r;
  try {
    r = await fetch(SESSION.verify_url, {
      headers: {
        cookie,
        'x-original-url': `${SESSION.public_url}${RT.base_path}${path}`,
        'x-original-method': method,
        accept: 'application/json',
      },
      redirect: 'manual',
      signal: AbortSignal.timeout(SESSION.timeout_ms),
    });
  } catch {
    const e = new Error('session verifier unreachable'); e.code = 'session_unavailable'; throw e;
  }
  const user = r.status === 200 ? r.headers.get('remote-user') : null;
  if (user) return user;
  const e = new Error(`session refused (${r.status})`);
  if (r.status >= 500) e.code = 'session_unavailable';
  throw e;
}

// ── CORS ──────────────────────────────────────────────────────────────────
// Echo ONLY a declared origin (exact, or https://<label>.<origin_suffix>). Never
// a wildcard, never Allow-Credentials: callers send a Bearer header, not cookies.
function corsOrigin(origin) {
  if (typeof origin !== 'string') return null;
  if (RT.cors.origins.includes(origin)) return origin;
  const sfx = RT.cors.origin_suffix;
  if (sfx) {
    const m = /^https:\/\/([a-z0-9-]+(?:\.[a-z0-9-]+)*)$/.exec(origin);
    // endsWith(".diegonmarcos.com"), dot included: "evil-diegonmarcos.com" must not pass.
    if (m && m[1].endsWith(sfx) && m[1].length > sfx.length) return origin;
  }
  return null;
}

function corsHeaders(req) {
  const o = corsOrigin(req.headers.origin);
  return o ? { 'access-control-allow-origin': o, vary: 'Origin' } : { vary: 'Origin' };
}

// ── Responses ─────────────────────────────────────────────────────────────
// One writer for every JSON body, so redaction cannot be forgotten on a path
// someone adds later.
function sendJson(res, status, obj, req) {
  const body = redactSecrets(obj, STORE.secrets);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...(req ? corsHeaders(req) : {}),
  });
  res.end(body);
}

const sendError = (res, status, code, error, req) => sendJson(res, status, { error, code }, req);

// A gate refusal carries {status, code}; anything else is ours (500).
function fromError(res, err, req) {
  if (err && err.code === 'bad_path') return sendError(res, 400, 'bad_path', err.message, req);
  if (err && err.status) return sendError(res, err.status, err.code, err.message, req);
  throw err;
}

// ── Handlers ──────────────────────────────────────────────────────────────
const HANDLERS = {
  '/me/health': async (req, res) => sendJson(res, 200, { status: 'ok', service: 'cloud-me-api' }, req),

  // The declared contract, minus the transport fields (ssh URL, key env names)
  // and the filter regexes: a client needs routes and dataset names, not how
  // the server reaches GitHub or what it refuses on.
  '/me/endpoints': async (req, res) => sendJson(res, 200, {
    ...RT,
    repos: { ...RT.repos, list: RT.repos.list.map((r) => ({ name: r.name, branch: r.branch })), known_hosts: undefined },
    files: { allowed_ext: RT.files.allowed_ext, max_bytes: RT.files.max_bytes },
  }, req),

  '/me/repos': async (req, res) => {
    sendJson(res, 200, { repos: STORE.repos().map((r) => ({
      name: r.name, branch: r.branch, commit: r.commit, synced_at: r.synced_at, ok: r.ok,
    })) }, req);
  },

  '/me/config/:name': async (req, res, { params }) => {
    const ds = RT.datasets[params.name];
    if (params.name.startsWith('_') || !ds || typeof ds !== 'object') {
      return sendError(res, 404, 'not_found', 'no such dataset', req);
    }
    try {
      const { text, commit } = STORE.read(ds.repo, ds.path);
      let json;
      try { json = JSON.parse(text); } catch { return sendError(res, 502, 'bad_dataset', 'dataset is not valid JSON', req); }
      res.setHeader('x-source-commit', commit.slice(0, 12));
      return sendJson(res, 200, json, req);
    } catch (err) { return fromError(res, err, req); }
  },

  '/me/repos/:repo/file': async (req, res, { params, query }) => {
    try {
      const { text, commit } = STORE.read(params.repo, query.get('path'));
      const body = redactSecrets(text, STORE.secrets);
      res.writeHead(200, {
        'content-type': 'text/plain; charset=utf-8',
        'content-length': Buffer.byteLength(body),
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
        'x-source-commit': commit.slice(0, 12),
        ...corsHeaders(req),
      });
      return res.end(body);
    } catch (err) { return fromError(res, err, req); }
  },
};

const TABLE = buildTable(RT, HANDLERS);

// ── Request pipeline ──────────────────────────────────────────────────────
async function serve(req, res, url) {
  const path = url.pathname.replace(/(.)\/+$/, '$1');

  // Preflight carries no credential by design (the browser strips it), so it is
  // answered before auth, but only for a declared origin and only with headers:
  // it discloses nothing and returns no data.
  if (req.method === 'OPTIONS') {
    const o = corsOrigin(req.headers.origin);
    if (!o) return sendError(res, 403, 'origin_not_allowed', 'origin is not declared', req);
    res.writeHead(204, {
      'access-control-allow-origin': o,
      'access-control-allow-methods': 'GET, OPTIONS',
      'access-control-allow-headers': 'Authorization, Content-Type',
      'access-control-max-age': '600',
      vary: 'Origin',
    });
    return res.end();
  }

  const hit = match(TABLE, req.method, path);
  if (hit === null) return sendError(res, 404, 'no_such_route', `No route for ${req.method} ${path}`, req);
  if (hit.route === null) {
    res.setHeader('allow', hit.allowed.join(', '));
    return sendError(res, 405, 'method_not_allowed', `${path} accepts ${hit.allowed.join(', ')}`, req);
  }

  if (hit.route.auth !== 'none') {
    // A presented bearer is authoritative; only a request with no Authorization
    // header at all is judged on its Authelia session.
    const decision = (req.headers.authorization || !req.headers.cookie)
      ? await decideAuth(req.headers.authorization, verifyAutheliaBearer, AUTH.required_scope)
      : await decideSession(req.headers.cookie, (c) => verifyAutheliaSession(c, req.method, path), SESSION.users);
    if (!decision.ok) return sendJson(res, decision.status, decision.body, req);
  }

  return hit.route.handler(req, res, { params: hit.params, query: url.searchParams });
}

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  serve(req, res, url).catch((err) => {
    if (res.headersSent) { res.destroy(); return; }
    return sendError(res, 500, 'internal_error', String((err && err.message) || err), req);
  });
});

// Keys are checked at startup: a service that could sync nothing should refuse
// to come up so the deploy-liveness gate catches it, not a user.
const missing = RT.repos.list.filter((r) => !STORE.hasKey(r.name) && !URL_OVERRIDE_DIR).map((r) => r.key_env);
if (missing.length) {
  console.error(`FATAL: deploy key env not set: ${missing.join(', ')} (expected from the sops-decrypted env_file)`);
  process.exit(1);
}

server.listen(PORT, HOST, () => {
  console.log(`cloud-me-api on ${HOST}:${PORT} — base_path ${RT.base_path}, ${TABLE.length} routes, ${RT.repos.list.length} repos`);
  const tick = () => STORE.syncAll().catch((e) => console.error('sync round failed:', redactSecrets(String(e.message), STORE.secrets)));
  tick();
  setInterval(tick, RT.repos.sync_interval_s * 1000).unref();
});
