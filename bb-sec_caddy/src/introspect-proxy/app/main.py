#!/usr/bin/env python3
"""
Authelia Token Introspection Proxy

A lightweight Flask service that validates Bearer tokens via Authelia's
OIDC introspection endpoint. Used by Caddy's forward_auth directive to
authenticate CLI/API clients.

Architecture:
    CLI Client -> Caddy (forward_auth) -> This Proxy -> Authelia Introspection
                                              |
                                              v
                                        200 OK + headers (valid)
                                        401 Unauthorized (invalid)
"""

import os
import logging
from flask import Flask, request, Response
import requests

# Configuration from environment
INTROSPECT_URL = os.environ.get(
    "INTROSPECT_URL",
    "https://auth.diegonmarcos.com/api/oidc/introspection"
)
CLIENT_ID = os.environ.get("CLIENT_ID", "cli")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET")
DEBUG = os.environ.get("DEBUG", "false").lower() == "true"

# Logging setup
logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)


@app.route("/auth", methods=["GET"])
def auth():
    """
    Validates Bearer token via Authelia introspection.

    Expected by Caddy forward_auth directive:
    - 2xx: Allow request, forward auth headers to backend
    - 401: Deny request

    Request Headers:
        Authorization: Bearer <token>

    Response Headers (on success):
        X-Auth-User: username from token
        X-Auth-Subject: sub claim from token
        X-Auth-Email: email from token (if available)
    """
    auth_header = request.headers.get("Authorization", "")

    if not auth_header.startswith("Bearer "):
        logger.debug("No Bearer token in Authorization header")
        return Response("No Bearer token", status=401)

    token = auth_header[7:]  # Remove "Bearer " prefix

    if not CLIENT_SECRET:
        logger.error("CLIENT_SECRET not configured")
        return Response("Server misconfigured", status=500)

    try:
        resp = requests.post(
            INTROSPECT_URL,
            data={"token": token},
            auth=(CLIENT_ID, CLIENT_SECRET),
            timeout=10
        )
        resp.raise_for_status()
    except requests.RequestException as e:
        logger.error(f"Introspection request failed: {e}")
        return Response("Auth server unavailable", status=502)

    try:
        data = resp.json()
    except ValueError:
        logger.error(f"Invalid JSON from introspection: {resp.text[:200]}")
        return Response("Invalid auth response", status=502)

    if data.get("active"):
        username = data.get("username", "")
        subject = data.get("sub", "")
        email = data.get("email", username)

        logger.info(f"Token valid for user: {username}")

        response = Response("OK", status=200)
        response.headers["X-Auth-User"] = username
        response.headers["X-Auth-Subject"] = subject
        response.headers["X-Auth-Email"] = email
        return response
    else:
        logger.debug(f"Token inactive or invalid")
        return Response("Token invalid or expired", status=401)


@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint for Docker/orchestration."""
    return Response("OK", status=200)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 4182))
    app.run(host="0.0.0.0", port=port, debug=DEBUG)
