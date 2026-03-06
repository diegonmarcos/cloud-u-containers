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

# Logging setup
logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# JWKS client with caching (re-fetches on key rotation)
_jwks_client = None
_jwks_client_created = 0
JWKS_CACHE_TTL = 3600  # re-create client every hour


def get_jwks_client():
    """Get or create a cached JWKS client."""
    global _jwks_client, _jwks_client_created
    now = time.time()
    if _jwks_client is None or (now - _jwks_client_created) > JWKS_CACHE_TTL:
        logger.info(f"Fetching JWKS from {JWKS_URL}")
        _jwks_client = PyJWKClient(JWKS_URL)
        _jwks_client_created = now
    return _jwks_client


@app.route("/auth", methods=["GET"])
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

    token = auth_header[7:]

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
        logger.error(f"JWKS fetch failed: {e}")
        # Reset client so next request retries
        global _jwks_client
        _jwks_client = None
        return Response("Auth key server unavailable", status=502)
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
