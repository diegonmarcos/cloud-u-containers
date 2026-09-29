// contract.mjs — reads the ONE endpoint declaration out of build.json.
//
// build.json is COPYed to /app/build.json by the image-wrapper generator
// (cloud-ship-container-step-build-docker.sh), so the block the service serves
// at GET /git/endpoints is byte-for-byte the block declared in build.json's
// `runtime`. There is deliberately no second copy of the route list anywhere in
// this tree — a drifting duplicate is how a client ends up dialling something
// the service never deployed (#371).
//
// Pure apart from the one file read, and the path is injectable so the tester
// can load the repo's build.json without being in the container.

import { readFileSync } from 'node:fs';

export function loadRuntime(buildJsonPath) {
  const raw = JSON.parse(readFileSync(buildJsonPath, 'utf8'));
  const rt = raw.runtime;
  if (!rt || !Array.isArray(rt.endpoints) || rt.endpoints.length === 0) {
    // Fail loudly at startup. A service that served an empty contract would be
    // indistinguishable from one with no routes, and the client would read the
    // empty list as "nothing available" rather than "this is broken".
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
  }
  return rt;
}

/**
 * Turn a declared path into the local path the server matches on.
 *
 * Caddy's `handle_path /git/*` strips the prefix before proxying, so the
 * container sees `/repos`, not `/git/repos`. The declared contract stays in the
 * caller's terms (what the phone dials) and this is the single place the two
 * spellings are reconciled.
 */
export function localPath(declaredPath, basePath) {
  const stripped = declaredPath.slice(basePath.length);
  return stripped === '' ? '/' : stripped;
}

/** Declared routes as `METHOD local/path`, the shape index.mjs registers. */
export function localRoutes(runtime) {
  return runtime.endpoints.map((e) => `${e.method} ${localPath(e.path, runtime.base_path)}`);
}
