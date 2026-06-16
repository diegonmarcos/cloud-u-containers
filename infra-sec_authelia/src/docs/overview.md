# Authelia Authentication

Authelia provides two-factor authentication (2FA) for all services behind the Caddy reverse proxy.

## Authentication Flow

1. User accesses a protected service (e.g., `photos.diegonmarcos.com`)
2. Caddy's `forward_auth` directive checks with Authelia
3. If not authenticated, user is redirected to `auth.diegonmarcos.com`
4. User completes 2FA (TOTP or WebAuthn)
5. Session cookie is set for `*.diegonmarcos.com`

## OIDC Provider

Authelia also acts as an OpenID Connect (OIDC) provider, issuing bearer tokens for CLI/API access via the `cli` client.

## Components

- **Authelia** — Main authentication server
- **Redis** — Session storage backend
