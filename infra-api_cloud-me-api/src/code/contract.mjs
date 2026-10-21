// contract.mjs — reads the ONE endpoint declaration out of build.json.
//
// build.json is COPYed to /app/build.json by the image-wrapper generator, so the
// block served at GET /me/endpoints is byte-for-byte the declared `runtime`.
// Validation is strict and runs at startup: a malformed declaration stops the
// service instead of 500ing the first request (or, worse, serving too much).

import { readFileSync } from 'node:fs';

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const ENV_RE = /^[A-Z][A-Z0-9_]{2,63}$/;

export function loadRuntime(buildJsonPath) {
  const raw = JSON.parse(readFileSync(buildJsonPath, 'utf8'));
  const rt = raw.runtime;
  if (!rt || !Array.isArray(rt.endpoints) || rt.endpoints.length === 0) {
    throw new Error('build.json runtime.endpoints is missing or empty');
  }
  if (typeof rt.base_path !== 'string' || !rt.base_path.startsWith('/')) {
    throw new Error('build.json runtime.base_path must be an absolute path');
  }
  for (const e of rt.endpoints) {
    if (!e.method || !e.path || !e.auth) {
      throw new Error(`build.json runtime.endpoints entry missing method/path/auth: ${JSON.stringify(e)}`);
    }
    if (!e.path.startsWith(rt.base_path)) {
      throw new Error(`endpoint ${e.path} does not sit under base_path ${rt.base_path}`);
    }
    // Only /health may be unauthenticated. A declared route that is open is a
    // data leak waiting for a data file, so it cannot even be declared.
    if (e.auth === 'none' && e.path !== `${rt.base_path}/health`) {
      throw new Error(`endpoint ${e.path} is auth "none": only ${rt.base_path}/health may be unauthenticated`);
    }
  }

  const r = rt.repos;
  if (!r || !Array.isArray(r.list) || r.list.length === 0 || !(r.sync_interval_s > 0) || !(r.git_timeout_ms > 0)) {
    throw new Error('build.json runtime.repos needs list[], sync_interval_s and git_timeout_ms');
  }
  if (!/^github\.com ssh-ed25519 \S+$/.test(r.known_hosts || '')) {
    throw new Error('build.json runtime.repos.known_hosts must pin the github.com ed25519 host key');
  }
  const seen = new Set();
  for (const x of r.list) {
    if (!NAME_RE.test(x.name || '') || seen.has(x.name)) throw new Error(`runtime.repos.list: bad or duplicate name ${x.name}`);
    seen.add(x.name);
    if (!/^git@github\.com:[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\.git$/.test(x.ssh || '')) {
      throw new Error(`runtime.repos.list ${x.name}: ssh must be git@github.com:owner/repo.git (deploy-key transport only)`);
    }
    if (!/^[A-Za-z0-9._/-]{1,100}$/.test(x.branch || '')) throw new Error(`runtime.repos.list ${x.name}: bad branch`);
    if (!ENV_RE.test(x.key_env || '')) throw new Error(`runtime.repos.list ${x.name}: key_env must be an env var name`);
    // The vault holds credentials. It is never a served repo, whatever else is declared.
    if (/vault/i.test(x.name) || /vault/i.test(x.ssh)) throw new Error(`runtime.repos.list ${x.name}: a vault repo cannot be served`);
  }

  const ds = rt.datasets || {};
  for (const [name, d] of Object.entries(ds)) {
    if (name.startsWith('_')) continue;
    if (!NAME_RE.test(name)) throw new Error(`runtime.datasets: bad name ${name}`);
    if (d.builtin !== undefined) {
      // Generated at build time from the fleet's build.json (gen-c3-datasets.mjs), shipped in the image.
      if (typeof d.builtin !== 'string' || !/^data\/[A-Za-z0-9_-]+\.json$/.test(d.builtin)) throw new Error(`runtime.datasets.${name}: builtin must be data/<name>.json`);
      continue;
    }
    if (!seen.has(d.repo)) throw new Error(`runtime.datasets.${name}: repo ${d.repo} is not declared in runtime.repos.list`);
    if (typeof d.path !== 'string' || !d.path.endsWith('.json')) throw new Error(`runtime.datasets.${name}: path must be a .json file`);
  }

  const f = rt.files;
  if (!f || !Array.isArray(f.allowed_ext) || f.allowed_ext.length === 0 || !f.allowed_ext.every((x) => /^\.[a-z0-9]+$/.test(x))
      || !(f.max_bytes > 0) || typeof f.deny_path !== 'string' || typeof f.deny_content !== 'string') {
    throw new Error('build.json runtime.files needs allowed_ext[], max_bytes, deny_path and deny_content');
  }
  new RegExp(f.deny_path, 'i');
  new RegExp(f.deny_content, 'im');

  const s = rt.authelia?.session;
  if (!s || !/^https:\/\//.test(s.verify_url || '') || !/^https:\/\/[^/]+$/.test(s.public_url || '')
      || !Array.isArray(s.users) || s.users.length === 0 || !(s.timeout_ms > 0)) {
    throw new Error('build.json runtime.authelia.session needs verify_url, public_url (origin), users[] and timeout_ms');
  }
  const c = rt.cors;
  if (!c || !Array.isArray(c.origins) || !c.origins.every((o) => /^https:\/\/[^/*]+$/.test(o))
      || (c.origin_suffix !== undefined && !/^\.[a-z0-9.-]+$/.test(c.origin_suffix))) {
    throw new Error('build.json runtime.cors needs https origins (no wildcard) and an optional .suffix');
  }
  return rt;
}

/** Caddy's handle_path strips the base path, so the server matches local paths. */
export function localPath(declaredPath, basePath) {
  const stripped = declaredPath.slice(basePath.length);
  return stripped === '' ? '/' : stripped;
}
