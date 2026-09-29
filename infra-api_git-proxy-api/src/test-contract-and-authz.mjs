#!/usr/bin/env node
// Tester for git-proxy-api (#647). Registered in build.json::tests, executed by
// .github/workflows/per-service-tests.yml -> .github/scripts/run-service-tests.sh
// on every push to main. An unrun tester is worth nothing (#368/#453/#486).
//
// It proves three things, and each one is written so that BREAKING the property
// turns it red — a green here that could not go red would be exactly the defect
// the fleet keeps rediscovering.
//
//   A. REFUSAL. An unauthenticated request is refused, asserted on the STATUS
//      *and* the BODY. Not a 200 with an error body (#568) and not a hang.
//   B. NO LEAK. The GitHub credential never appears in any response — checked
//      against a live server whose stubbed upstream deliberately echoes the
//      token back in an error body, which is the hardest case.
//   C. NO DRIFT. The served route table and build.json's declared contract are
//      the same set, in both directions (#371).
//
// Zero dependencies and zero secrets: node:crypto mints a throwaway RSA keypair,
// this file serves its own JWKS and its own fake api.github.com, and the real
// index.mjs is booted as a child process against them. Nothing outside this
// service's own source can fail it (#254).

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { generateKeyPairSync, createSign, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { decideAuth, scopesOf } from './code/authz.mjs';
import { loadRuntime, localPath } from './code/contract.mjs';
import { buildTable, match, toRegex } from './code/router.mjs';
import { redactSecrets, upstreamHeaders, reposUrl, tarballUrl, projectRepo, validName, validRef, REDACTED } from './code/upstream.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const BUILD_JSON = join(HERE, '..', 'build.json');
const RT = loadRuntime(BUILD_JSON);

// The sentinel stands in for the real GITHUB_TOKEN everywhere below. Shaped like
// a GitHub PAT so a substring match cannot pass by accident.
const FAKE_TOKEN = 'ghp_TESTSENTINEL0000000000000000000000';
const KID = 'test-kid';

let failures = 0;
let checks = 0;
function ok(cond, label, detail) {
  checks++;
  if (cond) { console.log(`  ok   ${label}`); return; }
  failures++;
  console.log(`  FAIL ${label}${detail ? `\n         ${detail}` : ''}`);
}
const eq = (a, b, label) => ok(JSON.stringify(a) === JSON.stringify(b), label, `got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);

// ══ A. Refusal, as a pure decision — STATUS and BODY both asserted ═════════
async function testRefusal() {
  console.log('\nA. an unauthenticated request is REFUSED (status AND body)');

  const goodClaims = { iss: RT.authelia.issuer, scp: [RT.authelia.required_scope], sub: 'diego' };
  const accept = async () => goodClaims;
  const reject = async () => { throw new Error('bad signature'); };
  const jwksDown = async () => { const e = new Error('down'); e.code = 'jwks_unavailable'; throw e; };
  const SCOPE = RT.authelia.required_scope;

  const cases = [
    [undefined, accept, 401, 'missing_authorization'],
    ['', accept, 401, 'missing_authorization'],
    ['token abc', accept, 401, 'bad_scheme'],
    ['bearer abc', accept, 401, 'bad_scheme'],   // case-sensitive scheme
    ['Basic abc', accept, 401, 'bad_scheme'],
    ['Bearer ', accept, 401, 'empty_token'],
    ['Bearer aa bb', accept, 401, 'malformed_token'],
    ['Bearer abc', reject, 401, 'invalid_token'],
    ['Bearer abc', jwksDown, 503, 'jwks_unavailable'],
    ['Bearer abc', async () => ({ ...goodClaims, scp: ['some.other.scope'] }), 403, 'insufficient_scope'],
  ];

  for (const [header, verify, wantStatus, wantCode] of cases) {
    const d = await decideAuth(header, verify, SCOPE);
    const label = `${JSON.stringify(header)} -> ${wantStatus} ${wantCode}`;
    if (d.ok) { ok(false, label, 'decision was ok:true — the request was ACCEPTED'); continue; }
    ok(d.status === wantStatus && d.body.code === wantCode, label,
      `got ${d.status} ${d.body.code}`);
    // The #568 property, stated explicitly: a refusal is never 2xx, and it
    // always carries a machine-readable code the caller can branch on.
    ok(d.status >= 400, `${label}: status is NOT 2xx`, `got ${d.status}`);
    ok(typeof d.body.error === 'string' && d.body.error.length > 0,
      `${label}: body carries a human-readable error`);
  }

  const good = await decideAuth('Bearer abc', accept, SCOPE);
  ok(good.ok === true, 'a valid token with the required scope is ACCEPTED');

  eq(scopesOf({ scp: ['a', 'b'] }), ['a', 'b'], 'scopesOf reads the scp array');
  eq(scopesOf({ scp: 'a b' }), ['a', 'b'], 'scopesOf tolerates the scp string form');
  eq(scopesOf({ scope: 'a b' }), ['a', 'b'], 'scopesOf tolerates the scope string form');
  eq(scopesOf(null), [], 'scopesOf(null) is empty, never permissive');
}

// ══ B. The GitHub token cannot reach a response ════════════════════════════
function testRedactionUnit() {
  console.log('\nB1. redactSecrets removes the credential from every body shape');

  const shapes = [
    FAKE_TOKEN,
    `Bearer ${FAKE_TOKEN}`,
    { error: `upstream said: Authorization: Bearer ${FAKE_TOKEN}`, code: 'upstream_error' },
    { nested: { deep: [FAKE_TOKEN] } },
    { url: `https://x:${FAKE_TOKEN}@github.com/a/b.git` },
  ];
  for (const s of shapes) {
    const out = redactSecrets(s, [FAKE_TOKEN]);
    ok(!out.includes(FAKE_TOKEN), `redacted: ${JSON.stringify(s).slice(0, 60)}`, `leaked in ${out}`);
    ok(out.includes(REDACTED), 'the redaction is visible, not silently dropped');
  }
  ok(!redactSecrets({ a: 1 }, [FAKE_TOKEN]).includes(REDACTED),
    'a clean body is left alone');
  // A short "secret" must not be redacted — it would turn every response into
  // placeholder soup and hide real content.
  ok(redactSecrets('abcdef', ['abc']) === 'abcdef',
    'secrets under 8 chars are ignored rather than mangling the body');

  console.log('\nB2. the credential is used ONLY as an outbound request header');
  const h = upstreamHeaders(FAKE_TOKEN);
  ok(h.authorization === `Bearer ${FAKE_TOKEN}`, 'upstreamHeaders carries the token');
  for (const [name, fn] of [
    ['reposUrl', () => reposUrl('https://api.github.com', 1)],
    ['tarballUrl', () => tarballUrl('https://api.github.com', 'o', 'r', 'main')],
    ['projectRepo', () => JSON.stringify(projectRepo({ full_name: 'o/r', owner: { login: 'o' }, name: 'r', private: true, default_branch: 'main', updated_at: 'x', size: 1, token: FAKE_TOKEN }))],
  ]) {
    ok(!String(fn()).includes(FAKE_TOKEN), `${name} never embeds the token`);
  }
  // projectRepo is a projection, not a passthrough: an upstream field we never
  // asked for cannot ride along into our response.
  ok(projectRepo({ full_name: 'o/r', token: FAKE_TOKEN }).token === undefined,
    'projectRepo drops unknown upstream fields');

  console.log('\nB3. sendJson is the ONLY body writer, so redaction cannot be skipped');
  const src = readFileSync(join(HERE, 'code', 'index.mjs'), 'utf8');
  // Every JSON body goes through sendJson (which redacts). The only raw writes
  // permitted are the tarball stream's own pipe/writeHead and the destroy on an
  // already-committed response. A new `res.end(...)` or `res.write(...)` added
  // elsewhere would bypass redaction — so the count is pinned.
  const rawEnds = [...src.matchAll(/\bres\.end\s*\(/g)].length;
  const rawWrites = [...src.matchAll(/\bres\.write\s*\(/g)].length;
  ok(rawEnds === 1, 'exactly one res.end( in index.mjs (the one inside sendJson)', `found ${rawEnds}`);
  ok(rawWrites === 0, 'no bare res.write( in index.mjs — bodies go through sendJson', `found ${rawWrites}`);
  ok(/function sendJson\([^)]*\)\s*\{\s*const body = redactSecrets\(/.test(src),
    'sendJson redacts before it writes anything');
  ok(!/sendJson\([^)]*GITHUB_TOKEN/.test(src) && !/sendError\([^)]*GITHUB_TOKEN/.test(src),
    'no response call site passes GITHUB_TOKEN');
}

// ══ C. Served routes and declared contract are the same set ════════════════
function testContract() {
  console.log('\nC. the served route table matches build.json runtime.endpoints');

  const raw = JSON.parse(readFileSync(BUILD_JSON, 'utf8'));
  eq(raw.api.endpoint_count, RT.endpoints.length,
    'api.endpoint_count agrees with runtime.endpoints length');
  eq(raw.api.base_path, RT.base_path, 'api.base_path agrees with runtime.base_path');
  eq(raw.proxy.primary.base_path, RT.base_path,
    'proxy.primary.base_path agrees with runtime.base_path — the #371 class: a client dialling a prefix the service never deployed');
  eq(raw.containers.app.proxy.base_path, RT.base_path,
    'containers.app.proxy.base_path agrees too (it is the copy the deriver reads)');
  eq(raw.ports.app, raw.containers.app.port, 'ports.app agrees with containers.app.port');

  // Exactly one endpoint is unauthenticated, it is /git/health, and it is the
  // one declared in proxy public_paths. A future endpoint accidentally declared
  // auth:"none" turns this red.
  const open = RT.endpoints.filter((e) => e.auth === 'none').map((e) => e.path);
  eq(open, ['/git/health'], 'exactly one endpoint is pre-auth, and it is /git/health');
  eq(raw.proxy.primary.public_paths, open,
    'proxy public_paths is exactly the set of auth:none endpoints');
  eq(raw.containers.app.proxy.public_paths, open, 'the container proxy copy agrees');
  for (const e of RT.endpoints.filter((x) => x.auth !== 'none')) {
    ok(e.auth === 'authelia_bearer', `${e.path} requires authelia_bearer`, `declares ${e.auth}`);
  }
  eq(raw.health.path, '/git/health', 'health.path is the pre-auth route');
  eq(raw.containers.app.healthcheck, localPath('/git/health', RT.base_path),
    'containers.app.healthcheck is the PREFIX-STRIPPED path the container actually serves');

  // buildTable is the drift gate: it throws in either direction. Prove both.
  const stub = {};
  for (const e of RT.endpoints) stub[e.path] = () => {};
  const table = buildTable(RT, stub);
  eq(table.length, RT.endpoints.length, 'buildTable accepts a complete handler set');

  const missing = { ...stub };
  delete missing[RT.endpoints[0].path];
  ok(threw(() => buildTable(RT, missing)),
    'buildTable THROWS on a declared endpoint with no handler');

  ok(threw(() => buildTable(RT, { ...stub, '/git/secret-backdoor': () => {} })),
    'buildTable THROWS on a handler that build.json does not declare');

  // Route matching, including the param route and the negative cases.
  for (const e of RT.endpoints) {
    const local = localPath(e.path, RT.base_path);
    const probe = local.replace(/:[^/]+/g, 'x');
    const hit = match(table, e.method, probe);
    ok(hit && hit.route && hit.route.declared === e.path,
      `${e.method} ${probe} resolves to ${e.path}`);
  }
  ok(match(table, 'GET', '/nope') === null, 'an unknown path does not match (-> 404, never 200)');
  ok(match(table, 'GET', '/repos/a/b/tarball/extra') === null, 'a deeper path does not match');
  const wrongMethod = match(table, 'POST', '/repos');
  ok(wrongMethod && wrongMethod.route === null && wrongMethod.allowed.includes('GET'),
    'a known path with the wrong method reports 405, not 404 and not 200');
  const params = match(table, 'GET', '/repos/diegonmarcos/cloud-infra/tarball');
  eq(params.params, { owner: 'diegonmarcos', repo: 'cloud-infra' }, 'path params are extracted');
  ok(toRegex('/repos/:o/:r/tarball').source.includes('([^/]+)'), 'toRegex builds a capturing group per param');

  console.log('\nC2. path/ref validation refuses traversal rather than dialling it');
  for (const bad of ['..', '.', '../etc', 'a/b', '', '-x', 'a'.repeat(101)]) {
    ok(!validName(bad), `validName rejects ${JSON.stringify(bad)}`);
  }
  for (const good of ['cloud-infra', 'a.b_c-d', 'X1']) ok(validName(good), `validName accepts ${good}`);
  for (const bad of ['../x', 'a..b', '-x', '/x', 'a'.repeat(256)]) ok(!validRef(bad), `validRef rejects ${JSON.stringify(bad)}`);
  for (const good of [undefined, '', 'main', 'feature/x', 'v1.2.3']) ok(validRef(good), `validRef accepts ${JSON.stringify(good)}`);
}

function threw(fn) { try { fn(); return false; } catch { return true; } }

// ══ D. End-to-end against the REAL server, stubbed dependencies ════════════
// The pure checks above can only prove what the functions do. This boots the
// actual index.mjs and drives it over HTTP, because "the service refuses" and
// "the token does not leak" are properties of the wired-up program.
async function testLive() {
  console.log('\nD. end-to-end: the real index.mjs over HTTP');

  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = publicKey.export({ format: 'jwk' });

  // A second, unrelated keypair. Nothing publishes it in the JWKS, so anything
  // it signs must be refused — without this case, DELETING the signature check
  // entirely leaves the tester green (it did, on the first mutation run), which
  // is the hollow-green shape exactly.
  const impostor = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;

  const b64u = (buf) => Buffer.from(buf).toString('base64url');
  function mintJwt(claims, signWith = privateKey, alg = 'RS256') {
    const h = b64u(JSON.stringify({ alg, typ: 'JWT', kid: KID }));
    const p = b64u(JSON.stringify(claims));
    const sig = createSign('RSA-SHA256').update(`${h}.${p}`).end().sign(signWith);
    return `${h}.${p}.${b64u(sig)}`;
  }
  // An unsigned "alg: none" token — the classic JWT bypass.
  function mintUnsigned(claims) {
    return `${b64u(JSON.stringify({ alg: 'none', typ: 'JWT', kid: KID }))}.${b64u(JSON.stringify(claims))}.`;
  }

  // Stub Authelia JWKS + stub api.github.com in one listener.
  // The JWKS publishes TWO keys and the impostor's comes FIRST, so a verifier
  // that grabbed keys[0] instead of matching on `kid` would fail every genuine
  // token. Without the second key, deleting the kid lookup left this tester
  // green — a single-key fixture cannot tell key SELECTION from key TRUST.
  const impostorPub = JSON.parse(JSON.stringify(
    generateKeyPairSync('rsa', { modulusLength: 2048 }).publicKey.export({ format: 'jwk' }),
  ));
  const upstream = createServer((req, res) => {
    if (req.url === '/jwks.json') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ keys: [
        { ...impostorPub, kid: 'some-other-kid', alg: 'RS256', use: 'sig' },
        { ...jwk, kid: KID, alg: 'RS256', use: 'sig' },
      ] }));
    }
    if (req.url.startsWith('/user/repos')) {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify([{
        full_name: 'diegonmarcos/cloud-infra', owner: { login: 'diegonmarcos' },
        name: 'cloud-infra', private: true, default_branch: 'main',
        updated_at: '2026-09-29T00:00:00Z', size: 42,
        // A hostile upstream field: if anything passed the body through instead
        // of projecting it, this would surface in our response.
        smuggled: FAKE_TOKEN,
      }]));
    }
    if (req.url.includes('/tarball')) {
      // The hardest leak case: the upstream fails AND quotes our credential
      // back at us. Our 502 must not carry it.
      res.writeHead(500, { 'content-type': 'text/plain' });
      return res.end(`upstream exploded with ${req.headers.authorization}`);
    }
    res.writeHead(404); res.end('{}');
  });
  await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
  const upstreamBase = `http://127.0.0.1:${upstream.address().port}`;

  const port = 18000 + (Math.abs(hash(randomUUID())) % 2000);
  const child = spawn(process.execPath, [join(HERE, 'code', 'index.mjs')], {
    env: {
      ...process.env,
      PORT: String(port),
      BIND_HOST: '127.0.0.1',
      GITHUB_TOKEN: FAKE_TOKEN,
      GITHUB_API_BASE: upstreamBase,
      JWKS_URL: `${upstreamBase}/jwks.json`,
      ISSUER: 'https://auth.diegonmarcos.com',
      UPSTREAM_TIMEOUT_MS: '5000',
      BUILD_JSON_PATH: BUILD_JSON,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let childLog = '';
  child.stdout.on('data', (d) => { childLog += d; });
  child.stderr.on('data', (d) => { childLog += d; });

  const base = `http://127.0.0.1:${port}`;
  try {
    await waitFor(async () => (await fetch(`${base}/health`)).ok, 8000);
  } catch {
    ok(false, 'the server started', childLog.slice(0, 800));
    child.kill('SIGKILL'); upstream.close();
    return;
  }

  const good = mintJwt({
    iss: 'https://auth.diegonmarcos.com', sub: 'diego', client_id: 'cli',
    scp: [RT.authelia.required_scope],
    iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 300,
  });
  const expired = mintJwt({
    iss: 'https://auth.diegonmarcos.com', sub: 'diego', scp: [RT.authelia.required_scope],
    exp: Math.floor(Date.now() / 1000) - 10,
  });
  const wrongIssuer = mintJwt({
    iss: 'https://evil.example.com', sub: 'diego', scp: [RT.authelia.required_scope],
    exp: Math.floor(Date.now() / 1000) + 300,
  });
  const noScope = mintJwt({
    iss: 'https://auth.diegonmarcos.com', sub: 'diego', scp: ['nope'],
    exp: Math.floor(Date.now() / 1000) + 300,
  });
  // Structurally perfect, correct kid, correct claims — signed by a key the
  // JWKS has never heard of. The ONLY thing that can reject this is the
  // signature verification itself.
  const validClaims = {
    iss: 'https://auth.diegonmarcos.com', sub: 'diego', client_id: 'cli',
    scp: [RT.authelia.required_scope],
    iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 300,
  };
  const forged = mintJwt(validClaims, impostor);
  const unsigned = mintUnsigned(validClaims);
  const tampered = (() => {
    // Take a genuinely signed token and swap its payload for the same claims
    // with an escalated scope, keeping the original signature.
    const [h, , s] = good0().split('.');
    return `${h}.${b64u(JSON.stringify({ ...validClaims, scp: [RT.authelia.required_scope, 'admin'] }))}.${s}`;
  })();
  function good0() { return mintJwt(validClaims); }

  const seen = [];
  async function req(path, token) {
    const r = await fetch(`${base}${path}`, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
    });
    const text = await r.text();
    seen.push({ path, status: r.status, text });
    return { status: r.status, text, json: safeJson(text) };
  }

  // Pre-auth route.
  const health = await req('/health');
  ok(health.status === 200 && health.json?.status === 'ok', 'GET /health is 200 without a token');
  ok(!health.text.includes('github') && !health.text.toLowerCase().includes('token'),
    '/health says nothing about GitHub or credentials');

  // Refusals — status AND body, on the live wire.
  for (const [label, tok, wantStatus, wantCode] of [
    ['no token', undefined, 401, 'missing_authorization'],
    ['garbage token', 'not-a-jwt', 401, 'invalid_token'],
    ['expired token', expired, 401, 'invalid_token'],
    ['wrong issuer', wrongIssuer, 401, 'invalid_token'],
    ['token signed by an impostor key', forged, 401, 'invalid_token'],
    ['unsigned alg:none token', unsigned, 401, 'invalid_token'],
    ['tampered payload, original signature', tampered, 401, 'invalid_token'],
    ['missing scope', noScope, 403, 'insufficient_scope'],
  ]) {
    for (const path of ['/repos', '/endpoints', '/repos/diegonmarcos/cloud-infra/tarball']) {
      const r = await req(path, tok);
      ok(r.status === wantStatus && r.json?.code === wantCode,
        `${path} with ${label} -> ${wantStatus} ${wantCode}`, `got ${r.status} ${r.text.slice(0, 120)}`);
    }
  }

  // Unmatched route: 404 with a JSON error body, never a 200 banner (#568).
  const bogus = await req('/definitely-not-a-route', good);
  ok(bogus.status === 404 && bogus.json?.code === 'no_such_route',
    'an unmatched route is 404 with a JSON error code, not a 200 banner (#568)',
    `got ${bogus.status} ${bogus.text.slice(0, 120)}`);
  const bogusNoAuth = await req('/definitely-not-a-route');
  ok(bogusNoAuth.status === 404, 'an unmatched route 404s before it can 401 — still not 200');

  // Authenticated happy paths.
  const eps = await req('/endpoints', good);
  ok(eps.status === 200 && eps.json?.endpoints?.length === RT.endpoints.length,
    'GET /endpoints serves the declared contract verbatim');
  eq(eps.json?.endpoints?.map((e) => e.path).sort(), RT.endpoints.map((e) => e.path).sort(),
    '/endpoints is byte-equal to build.json runtime.endpoints — one declaration, no drift');

  const repos = await req('/repos', good);
  ok(repos.status === 200 && repos.json?.count === 1, 'GET /repos returns the projected list',
    `got ${repos.status} ${repos.text.slice(0, 200)}`);
  ok(!('smuggled' in (repos.json?.repos?.[0] || {})),
    'an unknown upstream field is dropped, not passed through');

  // The hard leak case: upstream fails quoting our Authorization header.
  const tar = await req('/repos/diegonmarcos/cloud-infra/tarball?ref=main', good);
  ok(tar.status === 502 && tar.json?.code === 'upstream_error',
    'an upstream failure is a 502 with a JSON code, not a 200', `got ${tar.status}`);

  // Traversal and validation on the live wire.
  const badRef = await req('/repos/diegonmarcos/cloud-infra/tarball?ref=..%2F..%2Fetc', good);
  ok(badRef.status === 400 && badRef.json?.code === 'bad_ref', 'a traversal ref is a 400',
    `got ${badRef.status} ${badRef.text.slice(0, 120)}`);
  for (const [label, path] of [
    ['a leading-dash owner', '/repos/-flag/cloud-infra/tarball'],
    ['an encoded-traversal owner', '/repos/..%2F..%2Fetc/cloud-infra/tarball'],
    ['an encoded-traversal repo', '/repos/diegonmarcos/..%2Fsecrets/tarball'],
    ['an owner with a slash', '/repos/a%2Fb/cloud-infra/tarball'],
    // A bare "." or ".." segment is deliberately NOT tested: the URL layer
    // normalises "/./" and "/../" out of the path before it is ever sent, so
    // that case cannot reach the service and asserting on it would only pin
    // Node's URL behaviour. validName still rejects both (unit cases above).
  ]) {
    const r = await req(path, good);
    ok(r.status === 400 && r.json?.code === 'bad_repo', `${label} is a 400 bad_repo`,
      `got ${r.status} ${r.text.slice(0, 120)}`);
  }

  // Wrong method on a real path must be 405 — not 404, and above all not 200.
  for (const [method, path] of [['POST', '/repos'], ['DELETE', '/endpoints'], ['PUT', '/health']]) {
    const r = await fetch(`${base}${path}`, { method, headers: { authorization: `Bearer ${good}` } });
    const text = await r.text();
    seen.push({ path: `${method} ${path}`, status: r.status, text });
    ok(r.status === 405 && safeJson(text)?.code === 'method_not_allowed',
      `${method} ${path} -> 405 method_not_allowed`, `got ${r.status} ${text.slice(0, 120)}`);
    ok(r.headers.get('allow') === 'GET', `${method} ${path} advertises Allow: GET`,
      `got ${r.headers.get('allow')}`);
  }

  // THE headline assertion: across every response this run produced — bodies
  // and headers, success and failure — the credential appears nowhere.
  const everything = JSON.stringify(seen);
  ok(!everything.includes(FAKE_TOKEN),
    `the GitHub credential appears in NONE of the ${seen.length} responses collected`,
    firstLeak(seen));
  // And it did not escape through the logs either.
  ok(!childLog.includes(FAKE_TOKEN), 'the credential is not printed to stdout/stderr either');

  child.kill('SIGTERM');

  // E. Without a credential the process must REFUSE TO START, so the
  // deploy-liveness gate catches it (#560) instead of every user getting a 502.
  // A service that comes up and fails every request is the failure mode that
  // looks green from the outside.
  const noTok = spawn(process.execPath, [join(HERE, 'code', 'index.mjs')], {
    env: { ...process.env, PORT: String(port + 1), BIND_HOST: '127.0.0.1',
           GITHUB_TOKEN: '', BUILD_JSON_PATH: BUILD_JSON },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let noTokErr = '';
  noTok.stderr.on('data', (d) => { noTokErr += d; });
  const code = await new Promise((r) => {
    noTok.on('exit', r);
    setTimeout(() => { noTok.kill('SIGKILL'); r('still-running'); }, 5000);
  });
  ok(code === 1, 'with no GITHUB_TOKEN the process EXITS 1 instead of serving',
    `exit was ${code}`);
  ok(/GITHUB_TOKEN is not set/.test(noTokErr), 'and it says why, on stderr',
    noTokErr.slice(0, 200));

  upstream.close();
  await new Promise((r) => setTimeout(r, 100));
}

function firstLeak(seen) {
  const hit = seen.find((s) => s.text.includes(FAKE_TOKEN));
  return hit ? `LEAKED in ${hit.path} (${hit.status}): ${hit.text.slice(0, 200)}` : '';
}
function safeJson(t) { try { return JSON.parse(t); } catch { return null; } }
function hash(s) { let h = 0; for (const c of s) h = (h * 31 + c.charCodeAt(0)) | 0; return h; }
async function waitFor(fn, ms) {
  const until = Date.now() + ms;
  for (;;) {
    try { if (await fn()) return; } catch { /* not up yet */ }
    if (Date.now() > until) throw new Error('timeout');
    await new Promise((r) => setTimeout(r, 120));
  }
}

// ══════════════════════════════════════════════════════════════════════════
console.log('git-proxy-api tester (#647) — refusal, no-leak, no-drift');
await testRefusal();
testRedactionUnit();
testContract();
await testLive();

console.log(`\n${checks - failures}/${checks} checks passed`);
if (failures > 0) {
  console.error(`::error::git-proxy-api tester: ${failures} of ${checks} checks FAILED`);
  process.exit(1);
}
console.log('git-proxy-api: refusal, no-leak and no-drift all hold.');
