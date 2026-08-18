FROM caddy:2-builder AS builder
# Cache-bust 2026-05-08T15:46 — earlier build with @main pin produced an
# image missing caddy-dns/cloudflare; layer cache may retain a stale
# xcaddy resolve. This comment forces RUN-layer invalidation.
RUN xcaddy build \
    --with github.com/mholt/caddy-l4 \
    --with github.com/mholt/caddy-ratelimit \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

COPY Dockerfile /opt/cloud-builder/Dockerfile
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/bb-sec_caddy-l4-image/src/code/Dockerfile"
