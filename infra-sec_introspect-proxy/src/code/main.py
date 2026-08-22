#!/usr/bin/env python3
"""
JWT Validation Proxy

Validates Bearer JWTs locally using Authelia's JWKS public keys.
No dependency on Authelia's token database — only needs the public key
to verify RSA signatures.

Architecture:
    CLI Client -> Caddy (forward_auth) -> This Proxy -> Local JWT validation
                                              |              (JWKS cached)
                                              v
                                        200 OK + headers (valid)
                                        401 Unauthorized (invalid)
"""

import os
import time
import logging
import jwt
from flask import Flask, request, Response
from jwt import PyJWKClient

# Configuration from environment
JWKS_URL = os.environ.get("JWKS_URL", "https://auth.diegonmarcos.com/jwks.json")
ISSUER = os.environ.get("ISSUER", "https://auth.diegonmarcos.com")
REQUIRED_SCOPE = os.environ.get("REQUIRED_SCOPE", "authelia.bearer.authz")
DEBUG = os.environ.get("DEBUG", "false").lower() == "true"
# JWKS fetch must never eat into the caller's request budget (Cloudflare
# Worker fetches here have a ~10s deadline). Keep this well under that, and
# well under PyJWKClient's 30s default.
JWKS_FETCH_TIMEOUT = float(os.environ.get("JWKS_FETCH_TIMEOUT", "3"))

# Logging setup
logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# JWKS TTL, in seconds. PyJWKClient's own jwk-set cache (cache_jwk_set)
# refetches only after this many seconds; its per-kid signing-key cache
# (cache_keys) never expires, so a key already resolved once keeps working
# even while JWKS_URL is unreachable — a stale-but-valid key beats a hung
# request. Built once at import time: a single long-lived PyJWKClient is the
# whole point of caching, so it must never be thrown away on a fetch error
# (that used to force a full refetch, with the default 30s timeout, on every
# single request while Authelia was unreachable — the outage on 2026-08-22).
JWKS_CACHE_TTL = int(os.environ.get("JWKS_CACHE_TTL", "600"))  # 10 min
_jwks_client = PyJWKClient(
    JWKS_URL,
    cache_keys=True,
    cache_jwk_set=True,
    lifespan=JWKS_CACHE_TTL,
    timeout=JWKS_FETCH_TIMEOUT,
)


def get_jwks_client():
    """Return the shared, long-lived JWKS client (see caching note above)."""
    return _jwks_client


@app.route("/auth", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
def auth():
    """
    Validates Bearer JWT locally using JWKS public key.

    Expected by Caddy forward_auth directive:
    - 2xx: Allow request, forward auth headers to backend
    - 401: Deny request

    Request Headers:
        Authorization: Bearer <token>

    Response Headers (on success):
        X-Auth-User: client_id from token
        X-Auth-Subject: sub claim from token
        X-Auth-Email: email from token (if available)
    """
    auth_header = request.headers.get("Authorization", "")

    if not auth_header.startswith("Bearer "):
        logger.debug("No Bearer token in Authorization header")
        return Response("No Bearer token", status=401)

    token = auth_header[7:].strip()
    # JWT tokens are always ASCII — reject non-ASCII bytes
    if not token.isascii():
        logger.warning(f"Non-ASCII chars in token (len={len(token)}), stripping")
        token = token.encode('ascii', errors='ignore').decode('ascii')

    try:
        jwks_client = get_jwks_client()
        signing_key = jwks_client.get_signing_key_from_jwt(token)

        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            issuer=ISSUER,
            options={"verify_aud": False},
        )
    except jwt.ExpiredSignatureError:
        logger.debug("Token expired")
        return Response("Token expired", status=401)
    except jwt.InvalidIssuerError:
        logger.debug(f"Invalid issuer")
        return Response("Invalid token issuer", status=401)
    except jwt.PyJWKClientError as e:
        # Fail fast (short JWKS_FETCH_TIMEOUT above bounds this) rather than
        # hanging the caller. Do NOT drop _jwks_client here: it holds the
        # last-known-good JWKS/signing-key cache, which we want to keep
        # serving on the next request rather than forcing a fresh fetch.
        logger.error(f"JWKS fetch failed: {e}")
        return Response("Auth key server unavailable", status=503)
    except jwt.InvalidTokenError as e:
        logger.debug(f"Invalid token: {e}")
        return Response("Invalid token", status=401)

    # Check required scope
    scopes = payload.get("scp", [])
    if REQUIRED_SCOPE and REQUIRED_SCOPE not in scopes:
        logger.debug(f"Missing scope {REQUIRED_SCOPE}, has: {scopes}")
        return Response("Insufficient scope", status=403)

    client_id = payload.get("client_id", "")
    subject = payload.get("sub", "")

    logger.info(f"Token valid for client: {client_id}, sub: {subject}")

    response = Response("OK", status=200)
    response.headers["X-Auth-User"] = client_id
    response.headers["X-Auth-Subject"] = subject
    response.headers["X-Auth-Email"] = client_id
    return response


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint for Docker/orchestration."""
    return Response("OK", status=200)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 4182))
    app.run(host="0.0.0.0", port=port, debug=DEBUG)
