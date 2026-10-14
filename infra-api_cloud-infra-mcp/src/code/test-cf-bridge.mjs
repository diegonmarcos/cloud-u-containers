// Tests the policy behind the Cloudflare bridge (obs.debug.cf_api,
// obs.debug.cf_cloudflared, obs.debug.vps_wrangler, devops.cf.*):
// argument handling, read-only gating, credential-endpoint refusal, and
// redaction (cf-policy.ts + the shared redact-argv.ts helper from 079f067).
// Run: node --experimental-strip-types test-cf-bridge.mjs
import assert from "node:assert/strict";
import {
  cfAuthFromEnv, cfSecretValues, isGlobalApiKey, validateApiPath, gateWrite, fillPresetPath,
  tokenizeArgs, classifyCloudflared, classifyWrangler, redactCfJson, redactCfString, project,
  explainCfError, writeScopeFor, CF_READ_PRESETS, CF_REDACTED,
} from "./mcp/tools/cf-policy.ts";
import { redactCommandString } from "./shared/libs/redact-argv.ts";

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`ok - ${name}`); };
// Fake credentials are assembled at runtime so no literal here matches the
// fleet leak-scan shapes (.gitleaks.toml token-shape-*).
const GKEY = ["0123456789abcdef", "0123456789abcdef", "01234"].join("");   // 37 hex = global key shape
const TOKEN = ["Zx9AbCdEfGhIjKlMn", "OpQrStUvWxYz", "0123456789_-"].join(""); // 40+ chars = API token shape
const EYJ = "ey" + "J";
const none = (v, s) => assert.ok(!JSON.stringify(v).includes(s), `leaked: ${JSON.stringify(v)}`);

// ── auth ────────────────────────────────────────────────────────────────────
t("global key + email → X-Auth headers", () => {
  assert.ok(isGlobalApiKey(GKEY));
  const a = cfAuthFromEnv({ CF_API_KEY: GKEY, CF_API_EMAIL: "me@example.com" });
  assert.equal(a.mode, "global");
  assert.equal(a.headers["X-Auth-Key"], GKEY);
  assert.equal(a.headers.Authorization, undefined);
});
t("API token wins, and a token stored as CF_API_KEY is sent as Bearer", () => {
  assert.equal(cfAuthFromEnv({ CF_API_TOKEN: TOKEN, CF_API_KEY: GKEY, CF_API_EMAIL: "x@y" }).mode, "token");
  const a = cfAuthFromEnv({ CF_API_KEY: TOKEN });
  assert.equal(a.mode, "token");
  assert.equal(a.headers.Authorization, `Bearer ${TOKEN}`);
});
t("global key without email / nothing → none", () => {
  assert.equal(cfAuthFromEnv({ CF_API_KEY: GKEY }).mode, "none");
  assert.equal(cfAuthFromEnv({}).mode, "none");
});
t("secret values collected for exact-match scrubbing", () => {
  assert.deepEqual(cfSecretValues({ CF_API_KEY: GKEY, CF_API_TOKEN: TOKEN, CF_API_EMAIL: "a@b" }).sort(), [GKEY, TOKEN].sort());
});

// ── path validation / read-only gating ───────────────────────────────────────
t("normal GET paths accepted, full api URL normalised", () => {
  assert.deepEqual(validateApiPath("/accounts/abc/cfd_tunnel?is_deleted=false", "GET"), { ok: true, path: "/accounts/abc/cfd_tunnel?is_deleted=false" });
  assert.deepEqual(validateApiPath("zones", "GET"), { ok: true, path: "/zones" });
  assert.equal(validateApiPath("https://api.cloudflare.com/client/v4/zones", "GET").path, "/zones");
});
t("foreign hosts, traversal, whitespace, bad methods refused", () => {
  for (const p of ["https://evil.example/zones", "http://api.cloudflare.com/client/v4/zones", "/accounts/../user/tokens",
    "/accounts/a/%2e%2e/x", "/zones x", "/zones\n", "/a/%2Fb"]) assert.equal(validateApiPath(p, "GET").ok, false, p);
  assert.equal(validateApiPath("/zones", "HEAD").ok, false);
  assert.equal(validateApiPath("/zones", "CONNECT").ok, false);
});
t("credential endpoints refused for every method", () => {
  const bad = ["/user/tokens", "/user/tokens/abc", "/user/tokens?per_page=5", "/accounts/a/tokens", "/accounts/a/tokens/x/value",
    "/user/api_key", "/accounts/a/cfd_tunnel/0000-1111/token", "/accounts/a/warp_connector/x/token",
    "/accounts/a/access/service_tokens/x/rotate", "/accounts/a/access/service_tokens/x/refresh", "/accounts/a/members",
    "/accounts/a/access/certificates", "/accounts/a/access/gateway_ca"];
  for (const p of bad) for (const m of ["GET", "POST", "PUT", "DELETE"]) assert.equal(validateApiPath(p, m).ok, false, `${m} ${p}`);
  assert.equal(validateApiPath("/user/tokens/verify", "GET").ok, true);
  assert.equal(validateApiPath("/accounts/a/access/service_tokens", "GET").ok, true);
  assert.equal(validateApiPath("/accounts/a/cfd_tunnel/x/connections", "GET").ok, true);
});
t("writes are dry-run unless confirm === true", () => {
  assert.equal(gateWrite("GET", undefined).run, true);
  for (const m of ["POST", "PUT", "PATCH", "DELETE"]) {
    assert.equal(gateWrite(m, undefined).run, false);
    assert.equal(gateWrite(m, false).run, false);
    assert.equal(gateWrite(m, "true").run, false, "string 'true' is not confirmation");
    assert.equal(gateWrite(m, 1).run, false);
    assert.equal(gateWrite(m, true).run, true);
  }
  assert.equal(gateWrite("TRACE", true).run, false);
});
t("every preset is a GET-valid path once filled", () => {
  for (const [name, def] of Object.entries(CF_READ_PRESETS)) {
    const f = fillPresetPath(def.path, { account: "acc123", zone: "0123456789abcdef0123456789abcdef", id: "11111111-2222-3333-4444-555555555555" });
    assert.ok(f.ok, name);
    assert.ok(validateApiPath(f.path, "GET").ok, `${name}: ${f.path}`);
    assert.ok(def.scope.length > 0, name);
  }
});
t("preset ids cannot inject path segments", () => {
  assert.equal(fillPresetPath("/accounts/${account}/cfd_tunnel/${id}", { account: "a", id: "../../user/tokens" }).ok, false);
  assert.equal(fillPresetPath("/accounts/${account}/cfd_tunnel/${id}", { account: "a", id: "x?y=1" }).ok, false);
  assert.equal(fillPresetPath("/accounts/${account}/cfd_tunnel/${id}", { account: "a" }).ok, false);
});
t("write scopes named per area", () => {
  assert.match(writeScopeFor("/accounts/a/cfd_tunnel"), /Cloudflare Tunnel · Edit/);
  assert.match(writeScopeFor("/accounts/a/teamnet/routes"), /Cloudflare Tunnel · Edit/);
  assert.match(writeScopeFor("/accounts/a/access/apps"), /Apps and Policies · Edit/);
  assert.match(writeScopeFor("/accounts/a/access/service_tokens"), /Service Tokens · Edit/);
  assert.match(writeScopeFor("/accounts/a/access/identity_providers"), /Identity Providers/);
  assert.match(writeScopeFor("/accounts/a/gateway/rules"), /Zero Trust · Edit/);
  assert.match(writeScopeFor("/zones/z/dns_records"), /DNS · Edit/);
});
t("errors explain missing scope vs feature not enabled", () => {
  assert.match(explainCfError(403, [{ code: 10000, message: "Authentication error" }], "Account · Cloudflare Tunnel · Read"), /lacks: Account · Cloudflare Tunnel · Read/);
  assert.match(explainCfError(403, [{ code: 9999, message: "access.api.error.not_enabled: Access is not enabled." }], "x"), /not a token-scope problem/);
});

// ── argument handling ───────────────────────────────────────────────────────
t("tokenizer: quotes group, are removed, nothing else touched", () => {
  assert.deepEqual(tokenizeArgs(`tunnel route ip show`), ["tunnel", "route", "ip", "show"]);
  assert.deepEqual(tokenizeArgs(`kv key get "my key" --namespace-id='abc def'`), ["kv", "key", "get", "my key", "--namespace-id=abc def"]);
  assert.deepEqual(tokenizeArgs(`  a\t b  `), ["a", "b"]);
  assert.deepEqual(tokenizeArgs(``), []);
  assert.deepEqual(tokenizeArgs(`x "a'b"`), ["x", "a'b"]);
});
t("cloudflared read-only subcommands", () => {
  for (const c of ["version", "--version", "tunnel list", "tunnel info abc", "tunnel route ip show", "tunnel route ip get 10.0.0.1",
    "tunnel vnet list", "tunnel ingress validate", "access ssh-config --hostname h.example.com", "tunnel --help"])
    assert.equal(classifyCloudflared(tokenizeArgs(c)), "read", c);
});
t("cloudflared writes need the write tool", () => {
  for (const c of ["tunnel create t1", "tunnel delete t1", "tunnel cleanup t1", "tunnel route dns t1 a.example.com",
    "tunnel route ip add 10.0.0.0/24 t1", "tunnel vnet add v1"])
    assert.equal(classifyCloudflared(tokenizeArgs(c)), "write", c);
});
t("cloudflared credential / interactive / daemon subcommands blocked", () => {
  for (const c of ["tunnel token t1", "tunnel run t1", "login", "tunnel login", "access login https://x", "access token -app=https://x",
    "access tcp --hostname x", "service install", "update", "tunnel --cred-file /x list", "tunnel --token=abc list",
    "tunnel list --origincert /root/.cloudflared/cert.pem", "", "proxy-dns", "--loglevel debug"])
    assert.equal(classifyCloudflared(tokenizeArgs(c)), "blocked", c);
});
t("wrangler read-only subcommands", () => {
  for (const c of ["whoami", "--version", "kv namespace list", "kv key list --namespace-id abc", "r2 bucket list", "d1 list",
    "pages project list", "deployments list --name w", "versions view 1 --name w", "secret list --name w", "queues list"])
    assert.equal(classifyWrangler(tokenizeArgs(c)), "read", c);
});
t("wrangler writes (incl. sneaky read-looking args) need the write tool", () => {
  for (const c of ["deploy", "delete --name w", "kv key put k v --namespace-id a", "r2 bucket create b",
    "d1 execute db --command list", "d1 execute db --command \"SELECT 1\"", "kv namespace create n", "pages deploy dir", "versions deploy"])
    assert.equal(classifyWrangler(tokenizeArgs(c)), "write", c);
});
t("wrangler blocked: login, dev, tail, secret put", () => {
  for (const c of ["login", "logout", "dev", "tail w", "secret put X", "secret bulk f.json", "secret delete X", ""])
    assert.equal(classifyWrangler(tokenizeArgs(c)), "blocked", c);
});

// ── redaction ───────────────────────────────────────────────────────────────
t("tunnel create response: tunnel_secret + credentials_file + token redacted, ids kept", () => {
  const resp = {
    id: "11111111-2222-3333-4444-555555555555", name: "oci-apps", account_tag: "acc",
    credentials_file: { AccountTag: "acc", TunnelID: "1111", TunnelSecret: "c2VjcmV0c2VjcmV0c2VjcmV0" },
    tunnel_secret: "c2VjcmV0c2VjcmV0c2VjcmV0", token: EYJ + "hIjoiYWNjIiwidCI6IjExMTEiLCJzIjoiYzJWamNtVjBjMlZqY21WMCJ9" + "x".repeat(26),
  };
  const r = redactCfJson(resp);
  none(r, "c2VjcmV0c2VjcmV0c2VjcmV0"); none(r, EYJ + "hIjoi");
  assert.equal(r.id, resp.id); assert.equal(r.name, "oci-apps");
  assert.equal(r.tunnel_secret, CF_REDACTED); assert.equal(r.credentials_file, CF_REDACTED); assert.equal(r.token, CF_REDACTED);
});
t("service token create: client_secret redacted, client_id kept; policy token_id refs kept", () => {
  const r = redactCfJson({ id: "x", name: "ci", client_id: "abc.access", client_secret: "S3cr3tValue1234567890" });
  none(r, "S3cr3tValue"); assert.equal(r.client_id, "abc.access");
  const pol = redactCfJson({ include: [{ service_token: { token_id: "tok-uuid" } }, { any_valid_service_token: {} }] });
  assert.equal(pol.include[0].service_token.token_id, "tok-uuid");
});
t("list item `value` kept unless the object is a credential", () => {
  assert.deepEqual(redactCfJson([{ value: "10.0.0.0/8", created_at: "t" }]), [{ value: "10.0.0.0/8", created_at: "t" }]);
  const cred = redactCfJson({ name: "k", value: "abcd", secret: "zzz" });
  assert.equal(cred.value, CF_REDACTED); assert.equal(cred.secret, CF_REDACTED);
});
t("token-shaped strings redacted anywhere (JWT, tunnel token, PEM, Bearer, X-Auth-Key)", () => {
  const jwt = [EYJ + "hbGciOiJSUzI1NiJ9", EYJ + "zdWIiOiIxMjM0NTY3ODkwIn0", "c2lnbmF0dXJlc2lnbmF0dXJl"].join(".");
  const pem = ["-----BEGIN ARGO TUNNEL TOKEN-----", "abc", "-----END ARGO TUNNEL TOKEN-----"].join("\n");
  const s = redactCfString(`cf-access-token=${jwt} run --token ${EYJ}${"A".repeat(80)} ${pem} Authorization: ${"Bear" + "er"} ${TOKEN} X-Auth-Key: ${GKEY}`);
  for (const leak of [jwt, "A".repeat(80), "abc\n", TOKEN, GKEY]) assert.ok(!s.includes(leak), `leaked ${leak}: ${s}`);
  assert.match(s, /Bearer \*\*\*REDACTED\*\*\*/);
});
t("live credential values scrubbed by exact match, even in odd places", () => {
  const out = redactCfString(`error: header x-auth-key ${GKEY}; url https://x/?k=${TOKEN}`, [GKEY, TOKEN]);
  assert.ok(!out.includes(GKEY) && !out.includes(TOKEN));
});
t("composes with the shared redact-argv helper (wrangler/cloudflared output + audit target)", () => {
  const line = `cloudflared tunnel run --token ${TOKEN} --credentials-file /x.json ${"CLOUDFLARE_API_" + "TOKEN"}=${TOKEN}`;
  const out = redactCommandString(redactCfString(line, [TOKEN]));
  assert.ok(!out.includes(TOKEN), out);
});
t("projection picks nested fields and array lengths", () => {
  assert.deepEqual(project([{ id: 1, plan: { name: "Free" }, connections: [1, 2], x: 9 }], ["id", "plan.name", "connections.length"]),
    [{ id: 1, "plan.name": "Free", "connections.length": 2 }]);
  assert.deepEqual(project({ a: 1 }, undefined), { a: 1 });
});

console.log(`\n${n} tests passed`);
