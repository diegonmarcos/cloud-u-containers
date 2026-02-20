# Caddy Reverse Proxy

Declarative reverse proxy with automatic HTTPS, serving as the single entry point for all services.

## Traffic Flow

```
Cloudflare → Caddy (gcp-proxy) → WireGuard → target VM
```

## Authentication Layers

- **Browser sessions** — Authelia forward_auth (cookie-based)
- **CLI/API access** — Bearer token via introspect-proxy (OIDC introspection)

## Security Snippets

Caddy applies layered security: HSTS headers, bot blocking, scanner path blocking, rate limiting, request size limits, and JSON access logging.

## Components

- **Caddy** — Custom build with rate-limit plugin
- **introspect-proxy** — OIDC token introspection sidecar
