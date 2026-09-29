// authz.mjs — the authorization DECISION, as a pure function.
//
// Why the service verifies at all when Caddy already runs forward_auth against
// infra-sec_introspect-proxy: that edge gate does not exist when the container
// is dialled directly over the mesh (10.0.0.4:8123), and a service that hands
// out repository contents must not depend on its proxy for the only check.
// Making the decision a pure function of (header, verifier) is also what lets
// ../test-contract-and-authz.mjs assert the STATUS and the BODY of a refusal
// without a network, a real token, or an npm install.
//
// Pure: no imports, no I/O. `verify` is injected — index.mjs passes the real
// JWKS/RS256 verifier, the tester passes a stub.

export const SCHEME = 'Bearer ';

/**
 * @param {string|undefined} authHeader  raw Authorization header
 * @param {(token: string) => Promise<object>} verify  resolves to JWT claims,
 *        throws on any signature/issuer/expiry failure
 * @param {string} requiredScope
 * @returns {Promise<{ok: true, claims: object} | {ok: false, status: number, body: object}>}
 *
 * A refusal is ALWAYS a non-2xx status carrying {error, code}. Never a 200 with
 * an error body — that is the #568 defect verbatim (the mcp edge answered 200
 * with a banner on unmatched routes and every client read it as success), and
 * #646's fallback chain can only fall through on a signal it can distinguish.
 */
export async function decideAuth(authHeader, verify, requiredScope) {
  if (typeof authHeader !== 'string' || authHeader === '') {
    return refuse(401, 'missing_authorization', 'Authorization header required');
  }
  if (!authHeader.startsWith(SCHEME)) {
    return refuse(401, 'bad_scheme', `Authorization must use the ${SCHEME.trim()} scheme`);
  }

  const token = authHeader.slice(SCHEME.length).trim();
  if (token === '') {
    return refuse(401, 'empty_token', 'Bearer token is empty');
  }
  // A JWT is always ASCII. Rejecting rather than stripping: a token we had to
  // repair is a token we cannot claim to have verified.
  if (!/^[\x21-\x7e]+$/.test(token)) {
    return refuse(401, 'malformed_token', 'Bearer token is not a valid JWT');
  }

  let claims;
  try {
    claims = await verify(token);
  } catch (err) {
    // A JWKS outage is OURS, not the caller's, and must be a distinguishable
    // 503 so the client retries here instead of giving up on the whole route.
    if (err && err.code === 'jwks_unavailable') {
      return refuse(503, 'jwks_unavailable', 'Cannot reach the auth key server');
    }
    return refuse(401, 'invalid_token', 'Bearer token failed verification');
  }

  if (requiredScope && !scopesOf(claims).includes(requiredScope)) {
    return refuse(403, 'insufficient_scope', `Token lacks the ${requiredScope} scope`);
  }

  return { ok: true, claims };
}

/** Authelia puts scopes in `scp` (array); tolerate the `scope` string form too. */
export function scopesOf(claims) {
  if (!claims || typeof claims !== 'object') return [];
  if (Array.isArray(claims.scp)) return claims.scp;
  if (typeof claims.scp === 'string') return claims.scp.split(' ');
  if (typeof claims.scope === 'string') return claims.scope.split(' ');
  return [];
}

function refuse(status, code, error) {
  return { ok: false, status, body: { error, code } };
}
