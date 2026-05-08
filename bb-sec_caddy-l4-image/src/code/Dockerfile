FROM caddy:2-builder AS builder
# caddy-l4 pinned to @main to force fresh resolve — earlier unpinned build
# cached an older version with a prefetch-buffer bug that broke SNI matcher
# chains (multiple `tls { sni X }` matchers exhausted prefetch before all
# could read ClientHello). Phase 3 fix-forward 2026-05-08.
RUN xcaddy build \
    --with github.com/mholt/caddy-l4@main \
    --with github.com/mholt/caddy-ratelimit \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

COPY Dockerfile /opt/cloud-builder/Dockerfile
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/bb-sec_caddy-l4-image/src/code/Dockerfile"
