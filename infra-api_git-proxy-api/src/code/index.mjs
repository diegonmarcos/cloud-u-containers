#!/usr/bin/env node
// git-proxy-api — Authelia-fronted read path to GitHub (#647).
//
//   phone ──Authelia bearer──> Caddy (forward_auth introspect-proxy) ──> here
//                                                                        │
//                                              GITHUB_TOKEN (sops env_file)
//                                                                        v
//                                                            api.github.com
//
// The phone holds NO GitHub credential. It presents the Authelia bearer it
// already has (cloud-u-android auth.sign_in.providers[id=authelia],
// kind=authelia_bearer) and we do the GitHub work on its behalf. A lost phone
// leaks nothing about GitHub — which is what makes this the strongest leg of
// #646's fallback chain.
//
// Stdlib only: node:http for the server, WebCrypto for the RS256/JWKS verify,
// global fetch for the upstream. No npm dependencies at all, so nothing outside
// this service's own source can fail its release (#254).

import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { decideAuth } from './authz.mjs';
import { loadRuntime } from './contract.mjs';
import { buildTable, match } from './router.mjs';
import {
  upstreamHeaders, redactSecrets, reposUrl, tarballUrl,
  projectRepo, validName, validRef,
  repoDeclared, clampPerPage, feedUrl, FEED_KINDS,
} from './upstream.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

// /app/build.json in the image (the image-wrapper generator COPYs it next to
// the code); ../../build.json when run from the source tree.
function findBuildJson() {
  const candidates = [
    process.env.BUILD_JSON_PATH,
    join(HERE, 'build.json'),
    join(HERE, '..', '..', 'build.json'),
  ].filter(Boolean);
  const hit = candidates.find((p) => existsSync(p));
  if (!hit) throw new Error(`build.json not found; looked at ${candidates.join(', ')}`);
  return hit;
}

const RT = loadRuntime(findBuildJson());

// build.json is the DECLARATION; env vars override only so the tester can point
// the two outbound dependencies (Authelia's JWKS, api.github.com) at local
// stubs. Same pattern as infra-sec_introspect-proxy, whose compose.nix supplies
// JWKS_URL/ISSUER/REQUIRED_SCOPE from data. Nothing in production sets these.
const AUTH = {
  ...RT.authelia,
  jwks_url: process.env.JWKS_URL || RT.authelia.jwks_url,
  issuer: process.env.ISSUER || RT.authelia.issuer,
};
const API_BASE = process.env.GITHUB_API_BASE || RT.upstream.api_base;
const UPSTREAM_TIMEOUT_MS = Number(process.env.UPSTREAM_TIMEOUT_MS || RT.upstream.timeout_ms);

const PORT = Number(process.env.PORT || 8123);
const HOST = process.env.BIND_HOST || '0.0.0.0';
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';

// Every secret this process knows. Any string that reaches a client is passed
// through redactSecrets(_, SECRETS) first — unconditionally, not only on the
// paths that look risky.
const SECRETS = [GITHUB_TOKEN].filter(Boolean);

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

// ── Responses ─────────────────────────────────────────────────────────────
// One writer for every JSON body, so the redaction cannot be forgotten on a
// path someone adds later.
function sendJson(res, status, obj) {
  const body = redactSecrets(obj, SECRETS);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  });
  res.end(body);
}

const sendError = (res, status, code, error) => sendJson(res, status, { error, code });

// ── Upstream ──────────────────────────────────────────────────────────────
function ghFetch(url, accept) {
  const headers = upstreamHeaders(GITHUB_TOKEN);
  if (accept) headers.accept = accept;
  return fetch(url, {
    headers,
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    redirect: 'follow',
  });
}

// ── Feed cache (commits / runs of a declared repo) ──────────────────────────
// Keyed by (repo, kind) and always fetched at max_per_page, so the key space
// is bounded by the allow-list and the fleet's polling costs at most
// 2 x len(feeds.repos) upstream calls per TTL. The in-flight promise is what is
// cached, so concurrent misses share ONE upstream call. Failures are evicted,
// never cached: the next caller retries instead of being served a stale error.
const FEEDS = RT.feeds;
const FEED_CACHE = new Map();

function cachedFeed(owner, repo, kind) {
  const key = `${owner}/${repo}`.toLowerCase() + `:${kind}`;
  const hit = FEED_CACHE.get(key);
  if (hit && Date.now() - hit.at < FEEDS.cache_ttl_s * 1000) return hit.p;
  const p = (async () => {
    const r = await ghFetch(feedUrl(API_BASE, owner, repo, kind, FEEDS.max_per_page));
    if (!r.ok) {
      const e = new Error(`GitHub returned ${r.status} for ${kind}`);
      e.upstreamStatus = r.status;
      throw e;
    }
    const list = FEED_KINDS[kind].list(await r.json());
    if (!Array.isArray(list)) throw new Error(`GitHub returned a non-list for ${kind}`);
    return { items: list.map(FEED_KINDS[kind].project), cached_at: new Date().toISOString() };
  })();
  FEED_CACHE.set(key, { p, at: Date.now() });
  p.catch(() => { if (FEED_CACHE.get(key)?.p === p) FEED_CACHE.delete(key); });
  return p;
}

function feedHandler(kind) {
  return async (_req, res, { params, query }) => {
    const { owner, repo } = params;
    if (!validName(owner) || !validName(repo)) {
      return sendError(res, 400, 'bad_repo', 'owner and repo must be valid GitHub names');
    }
    // Checked BEFORE anything is dialled: an undeclared repo costs no quota.
    if (!repoDeclared(FEEDS.repos, owner, repo)) {
      return sendError(res, 403, 'repo_not_declared', `${owner}/${repo} is not in runtime.feeds.repos`);
    }
    let feed;
    try {
      feed = await cachedFeed(owner, repo, kind);
    } catch (err) {
      if (err.upstreamStatus === undefined) throw err; // timeout -> 504 in serve()
      const notFound = err.upstreamStatus === 404;
      return sendError(res, notFound ? 404 : 502, notFound ? 'not_found' : 'upstream_error', err.message);
    }
    const n = clampPerPage(query.get('per_page'), FEEDS.max_per_page);
    return sendJson(res, 200, { repo: `${owner}/${repo}`, [kind]: feed.items.slice(0, n), cached_at: feed.cached_at });
  };
}

// ── Handlers, keyed by the DECLARED path in build.json runtime.endpoints ───
const HANDLERS = {
  '/git/health': async (_req, res) => sendJson(res, 200, { status: 'ok', service: 'git-proxy-api' }),

  '/git/endpoints': async (_req, res) => sendJson(res, 200, {
    base_path: RT.base_path,
    endpoints: RT.endpoints,
  }),

  '/git/repos': async (_req, res) => {
    const out = [];
    // GitHub caps per_page at 100; walk until a short page. Bounded at 10 pages
    // so a pagination bug cannot turn one request into an unbounded loop.
    for (let page = 1; page <= 10; page++) {
      const r = await ghFetch(reposUrl(API_BASE, page));
      if (!r.ok) {
        return sendError(res, 502, 'upstream_error', `GitHub returned ${r.status} listing repositories`);
      }
      const batch = await r.json();
      if (!Array.isArray(batch)) {
        return sendError(res, 502, 'upstream_error', 'GitHub returned a non-list for repositories');
      }
      out.push(...batch.map(projectRepo));
      if (batch.length < 100) break;
    }
    return sendJson(res, 200, { repos: out, count: out.length });
  },

  '/git/repos/:owner/:repo/tarball': async (req, res, { params, query }) => {
    const { owner, repo } = params;
    const ref = query.get('ref') || undefined;
    if (!validName(owner) || !validName(repo)) {
      return sendError(res, 400, 'bad_repo', 'owner and repo must be valid GitHub names');
    }
    if (!validRef(ref)) {
      return sendError(res, 400, 'bad_ref', 'ref is not a valid git ref');
    }

    const r = await ghFetch(tarballUrl(API_BASE, owner, repo, ref), 'application/vnd.github+json');
    if (!r.ok) {
      // 404 is forwarded as 404 so the caller can tell "no such repo" from "we
      // are broken" — a fallback chain needs that distinction to decide whether
      // to try the next leg or to stop.
      const notFound = r.status === 404;
      return sendError(res, notFound ? 404 : 502,
        notFound ? 'not_found' : 'upstream_error',
        `GitHub returned ${r.status} for the tarball`);
    }
    if (!r.body) {
      return sendError(res, 502, 'upstream_error', 'GitHub returned an empty tarball body');
    }

    res.writeHead(200, {
      'content-type': 'application/gzip',
      'content-disposition': `attachment; filename="${repo}.tar.gz"`,
      'cache-control': 'no-store',
    });
    // Straight through — nothing is written to disk. oci disks have sat at
    // 87-97% and an unscoped prune has destroyed services twice (#353/#393),
    // so this service never stages a repository anywhere.
    await new Promise((resolve, reject) => {
      const src = Readable.fromWeb(r.body);
      src.on('error', reject);
      res.on('close', resolve);
      src.pipe(res).on('finish', resolve).on('error', reject);
    });
  },

  '/git/repos/:owner/:repo/commits': feedHandler('commits'),
  '/git/repos/:owner/:repo/runs': feedHandler('runs'),
};

// Throws if build.json and HANDLERS disagree in EITHER direction — the service
// structurally cannot start in a drifted state.
const TABLE = buildTable(RT, HANDLERS);

// ── Request pipeline ──────────────────────────────────────────────────────
async function serve(req, res, url) {
  const path = url.pathname.replace(/(.)\/+$/, '$1');
  const hit = match(TABLE, req.method, path);

  if (hit === null) {
    // An unmatched route is a 404 with a JSON error body. Never a 200 with a
    // banner: that is #568 verbatim (the mcp edge answered 200 on unmatched
    // routes and every client read it as success), and #646's chain must be
    // able to fall through on a signal it can distinguish from success.
    return sendError(res, 404, 'no_such_route', `No route for ${req.method} ${path}`);
  }
  if (hit.route === null) {
    res.setHeader('allow', hit.allowed.join(', '));
    return sendError(res, 405, 'method_not_allowed', `${path} accepts ${hit.allowed.join(', ')}`);
  }

  if (hit.route.auth !== 'none') {
    const decision = await decideAuth(req.headers.authorization, verifyAutheliaBearer, AUTH.required_scope);
    if (!decision.ok) return sendJson(res, decision.status, decision.body);
  }

  return hit.route.handler(req, res, { params: hit.params, query: url.searchParams });
}

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  serve(req, res, url).catch((err) => {
    if (res.headersSent) { res.destroy(); return; }
    // A hang is the one failure #646's chain cannot fall through on, so an
    // upstream that ran out of time becomes an explicit 504.
    if (err && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
      return sendError(res, 504, 'upstream_timeout', 'GitHub did not answer in time');
    }
    // redactSecrets runs inside sendJson, so even an upstream error message
    // that quoted the token cannot leave here readable.
    return sendError(res, 500, 'internal_error', String((err && err.message) || err));
  });
});

// GITHUB_TOKEN is checked at startup, not per request: a service that would 502
// every call is better off refusing to come up, so the deploy-liveness gate
// catches it instead of a user (#560).
if (!GITHUB_TOKEN) {
  console.error('FATAL: GITHUB_TOKEN is not set (expected from the sops-decrypted env_file)');
  process.exit(1);
}

server.listen(PORT, HOST, () => {
  console.log(`git-proxy-api on ${HOST}:${PORT} — base_path ${RT.base_path}, ${TABLE.length} routes`);
});
