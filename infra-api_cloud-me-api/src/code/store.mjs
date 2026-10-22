// store.mjs — the read-only mirror of the declared private repos, and the file
// gate in front of it.
//
// Transport is git over SSH with a per-repo READ-ONLY deploy key (GitHub deploy
// keys are read-only unless created with write access; the key id is checked by
// the operator at creation, and nothing here ever pushes). Clones are shallow
// and live under dataDir (a tmpfs in production). The private keys come from
// env as base64, are written 0600 under keyDir, and are never logged or served.

import { execFile } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, rmSync, realpathSync, lstatSync, readFileSync } from 'node:fs';
import { join, resolve, sep, extname, posix } from 'node:path';

const REDACTED = '[REDACTED]';

/** Replace every known secret (and its base64) in a string. Never partial-match short values. */
export function redactSecrets(value, secrets) {
  let out = typeof value === 'string' ? value : JSON.stringify(value);
  const list = (secrets || []).filter((s) => typeof s === 'string' && s.length >= 8);
  for (const s of [...list].sort((a, b) => b.length - a.length)) out = out.split(s).join(REDACTED);
  return out;
}

/**
 * Validate a caller-supplied repo-relative path. Returns the normalised posix
 * path or throws {code}. Rejects absolute paths, traversal, NUL, backslashes.
 */
export function cleanPath(p) {
  const bad = (m) => Object.assign(new Error(m), { code: 'bad_path' });
  if (typeof p !== 'string' || p === '' || p.length > 300) throw bad('path is required (max 300 chars)');
  if (p.includes('\0') || p.includes('\\')) throw bad('path contains forbidden characters');
  if (p.startsWith('/')) throw bad('path must be relative');
  const n = posix.normalize(p);
  if (n === '..' || n.startsWith('../') || n.split('/').includes('..') || n === '.' || n.endsWith('/')) throw bad('path escapes the repository');
  return n;
}

/** The file gate. `files` is runtime.files. Throws {code,status} on refusal. */
export function makeGate(files) {
  const denyPath = new RegExp(files.deny_path, 'i');
  const denyContent = new RegExp(files.deny_content, 'im');
  const fail = (status, code, message) => Object.assign(new Error(message), { status, code });
  return {
    checkPath(rel) {
      if (!files.allowed_ext.includes(extname(rel).toLowerCase())) throw fail(403, 'path_denied', 'file type is not served');
      if (denyPath.test(rel)) throw fail(403, 'path_denied', 'path is not served');
    },
    checkSize(size) {
      if (size > files.max_bytes) throw fail(413, 'too_large', `file exceeds ${files.max_bytes} bytes`);
    },
    checkContent(text) {
      if (denyContent.test(text)) throw fail(403, 'secret_filtered', 'file looks like it holds a secret and is never served');
    },
  };
}

function git(args, { cwd, env, timeout }) {
  return new Promise((res, rej) => {
    execFile('git', args, { cwd, env, timeout, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
      if (err) { err.stderr = String(stderr || ''); return rej(err); }
      res(String(stdout));
    });
  });
}

/**
 * @param {object} o
 *  repos: runtime.repos.list; files: runtime.files; dataDir/keyDir: writable dirs;
 *  env: process env (key_env values); knownHosts: pinned host key line;
 *  gitTimeoutMs; urlFor(repo) -> clone URL (production: repo.ssh; tests: a local path)
 */
export function createStore(o) {
  const gate = makeGate(o.files);
  const state = new Map(); // name -> {commit, synced_at, ok}
  const keys = new Map();  // name -> key path
  const secrets = [];

  mkdirSync(o.keyDir, { recursive: true, mode: 0o700 });
  mkdirSync(o.dataDir, { recursive: true });
  const knownHostsPath = join(o.keyDir, 'known_hosts');
  writeFileSync(knownHostsPath, `${o.knownHosts}\n`, { mode: 0o600 });

  for (const r of o.repos) {
    state.set(r.name, { commit: null, synced_at: null, ok: false });
    const b64 = (o.env[r.key_env] || '').trim();
    if (!b64) continue;
    const pem = Buffer.from(b64, 'base64').toString('utf8');
    secrets.push(b64, pem, ...pem.split('\n').filter((l) => l.length >= 16));
    const p = join(o.keyDir, `${r.name}.key`);
    writeFileSync(p, pem.endsWith('\n') ? pem : `${pem}\n`, { mode: 0o600 });
    keys.set(r.name, p);
  }

  const sshCmd = (keyPath) => ['ssh', '-F', '/dev/null', '-i', keyPath, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=yes', '-o', `UserKnownHostsFile=${knownHostsPath}`].join(' ');

  async function sync(repo) {
    const dir = join(o.dataDir, repo.name);
    const keyPath = keys.get(repo.name);
    const env = { PATH: process.env.PATH, HOME: o.keyDir, GIT_TERMINAL_PROMPT: '0',
      ...(keyPath ? { GIT_SSH_COMMAND: sshCmd(keyPath) } : {}) };
    const opt = { cwd: o.dataDir, env, timeout: o.gitTimeoutMs };
    try {
      if (!existsSync(join(dir, '.git'))) {
        rmSync(dir, { recursive: true, force: true });
        await git(['clone', '--quiet', '--depth', '1', '--single-branch', '--branch', repo.branch, o.urlFor(repo), dir], opt);
      } else {
        await git(['fetch', '--quiet', '--depth', '1', 'origin', repo.branch], { ...opt, cwd: dir });
        await git(['reset', '--quiet', '--hard', 'FETCH_HEAD'], { ...opt, cwd: dir });
      }
      const commit = (await git(['rev-parse', 'HEAD'], { ...opt, cwd: dir })).trim();
      state.set(repo.name, { commit, synced_at: new Date().toISOString(), ok: true });
      return true;
    } catch (err) {
      // Keep serving the last good checkout; only flag the repo. The message is
      // logged redacted and NEVER sent to a client.
      const prev = state.get(repo.name);
      state.set(repo.name, { ...prev, ok: false });
      console.error(`sync ${repo.name} failed: ${redactSecrets(String(err.stderr || err.message).trim().split('\n')[0], secrets)}`);
      return false;
    }
  }

  const byName = (n) => o.repos.find((r) => r.name === n);

  // personal: the ONE declared personal file (runtime.autocomplete) skips the deny_path / deny_content secret filters
  // (it is secrets by nature); every other check stays: declared repo, clean path, extension, size, no symlink out, no .git.
  function read(repoName, relRaw, { personal = false } = {}) {
    const fail = (status, code, message) => Object.assign(new Error(message), { status, code });
    const repo = byName(repoName);
    if (!repo) throw fail(403, 'repo_not_declared', 'repo is not declared');
    const rel = cleanPath(relRaw);
    // the personal file is served by its own route only, never through the generic file or dataset routes
    if (!personal && o.personal && o.personal.repo === repoName && o.personal.path === rel) throw fail(403, 'path_denied', 'path is not served');
    if (personal) {
      if (!o.files.allowed_ext.includes(extname(rel).toLowerCase())) throw fail(403, 'path_denied', 'file type is not served');
    } else gate.checkPath(rel);
    const st = state.get(repoName);
    const dir = join(o.dataDir, repoName);
    if (!st.commit || !existsSync(dir)) throw fail(503, 'not_synced', 'repo has not synced yet');
    const root = realpathSync(dir);
    const abs = resolve(root, rel);
    let real;
    try { real = realpathSync(abs); } catch { throw fail(404, 'not_found', 'no such file'); }
    // A symlink inside the repo must not lead out of it, and .git is never readable.
    if (real !== root && !real.startsWith(root + sep)) throw fail(403, 'path_denied', 'path is not served');
    if (real.slice(root.length).split(sep).includes('.git')) throw fail(403, 'path_denied', 'path is not served');
    const ls = lstatSync(real);
    if (!ls.isFile()) throw fail(404, 'not_found', 'no such file');
    gate.checkSize(ls.size);
    const text = readFileSync(real, 'utf8');
    if (!personal) gate.checkContent(text);
    return { text, commit: st.commit };
  }

  return {
    secrets,
    gate,
    repos: () => o.repos.map((r) => ({ name: r.name, branch: r.branch, ...state.get(r.name) })),
    syncAll: () => Promise.all(o.repos.map(sync)),
    sync: (name) => sync(byName(name)),
    read,
    hasKey: (name) => keys.has(name),
  };
}
