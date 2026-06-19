FROM caddy:2-builder AS builder
# Cache-bust 2026-06-19 — xcaddy resolves the plugins; the comment forces
# RUN-layer invalidation if a stale layer cache ever drops a plugin.
RUN xcaddy build \
    --with github.com/mholt/caddy-l4 \
    --with github.com/mholt/caddy-ratelimit \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Self-contained: only COPYs the Dockerfile itself, so the build context is
# just dist/code/<arch>/ (no nativeBuild.extraFiles needed).
COPY Dockerfile /opt/cloud-builder/Dockerfile
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/infra-sec_caddy/src/code/Dockerfile"
