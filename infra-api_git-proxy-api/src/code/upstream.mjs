// upstream.mjs — the ONLY place the GitHub credential is allowed to appear,
// plus the redactor every outbound body is passed through.
//
// Pure: no imports, no I/O. index.mjs does the fetching; this module only
// builds URLs/headers and scrubs strings, which is what makes
// ../test-contract-and-authz.mjs able to assert the leak properties without a
// network, a token, or an npm install.

// Placeholder written into any string where a secret was found. Distinct and
// greppable so a leak that DID get redacted is still visible in a log.
export const REDACTED = '[redacted]';

/**
 * Outbound headers for api.github.com. This is the one function in the service
 * that embeds the token, and it is only ever used on a REQUEST we send.
 */
export function upstreamHeaders(token) {
  if (!token) throw new Error('upstreamHeaders: no GITHUB_TOKEN configured');
  return {
    authorization: `Bearer ${token}`,
    accept: 'application/vnd.github+json',
    'x-github-api-version': '2022-11-28',
    'user-agent': 'git-proxy-api',
  };
}

/**
 * Remove every configured secret from a string before it can reach a client.
 *
 * Applied to EVERY response body this service emits, not just the ones that
 * look risky. An upstream error message, a stack trace, a URL echoed back in a
 * 502 — any of them can carry a token, and the honest way to be sure is to
 * scrub unconditionally rather than to reason case by case about which path is
 * safe. Longest secret first so a token that contains another secret as a
 * substring cannot leave a readable tail behind.
 */
export function redactSecrets(value, secrets) {
  let out = typeof value === 'string' ? value : JSON.stringify(value);
  const list = (secrets || []).filter((s) => typeof s === 'string' && s.length >= 8);
  for (const s of [...list].sort((a, b) => b.length - a.length)) {
    out = out.split(s).join(REDACTED);
  }
  return out;
}

export function reposUrl(apiBase, page) {
  const p = Number.isInteger(page) && page > 0 ? page : 1;
  return `${apiBase}/user/repos?per_page=100&page=${p}&affiliation=owner,collaborator,organization_member`;
}

export function tarballUrl(apiBase, owner, repo, ref) {
  const seg = [owner, repo].map((s) => encodeURIComponent(s)).join('/');
  // No ref => GitHub uses the repo's default branch, which is exactly the
  // "just give me the repo" case and saves a round trip to look it up.
  return ref
    ? `${apiBase}/repos/${seg}/tarball/${encodeURIComponent(ref)}`
    : `${apiBase}/repos/${seg}/tarball`;
}

/** Project an upstream repo object down to the fields a client needs.
 *
 * A projection, not a passthrough: whatever GitHub adds to its schema later
 * cannot appear in our response, so no upstream field can become a leak. */
export function projectRepo(r) {
  return {
    full_name: r.full_name,
    owner: r.owner?.login,
    name: r.name,
    private: !!r.private,
    default_branch: r.default_branch,
    updated_at: r.updated_at,
    size_kb: r.size,
  };
}

// Owner/repo path segments, validated against GitHub's own naming rules. A
// request for `../../secrets` must be a 400 from us, never a URL we construct
// and dial.
const NAME_RE = /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,99})$/;

export function validName(s) {
  return typeof s === 'string' && NAME_RE.test(s) && s !== '.' && s !== '..';
}

// A git ref may contain slashes (feature/x) but never `..`, a leading dash, or
// the traversal shapes that would let a caller rewrite the upstream path.
export function validRef(s) {
  if (s === undefined || s === null || s === '') return true;
  if (typeof s !== 'string' || s.length > 255) return false;
  if (s.includes('..') || s.startsWith('-') || s.startsWith('/')) return false;
  return /^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(s);
}
