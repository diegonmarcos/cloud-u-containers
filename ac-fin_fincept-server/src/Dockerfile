# syntax=docker/dockerfile:1.6
#
# Self-contained build of fincept-server. The fincept-rs workspace lives
# entirely in ./fincept-rs (sibling of this Dockerfile) — no external repos,
# no submodules. Build context is this src/ directory (cloud engine default).
#
# Multi-stage: rust builder → debian slim runtime. Strips debug symbols so
# the final image stays small despite a 50-crate workspace.

ARG RUST_VERSION=1.83

FROM rust:${RUST_VERSION}-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY fincept-rs/ ./

ENV CARGO_NET_RETRY=10 CARGO_INCREMENTAL=0
RUN cargo build --release --bin fincept-server \
    && strip target/release/fincept-server


# ── Runtime ─────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libssl3 curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r fincept && useradd -r -g fincept -u 1000 fincept

COPY --from=builder /build/target/release/fincept-server /usr/local/bin/fincept-server

USER fincept
ENV RUST_LOG=info,tower_http=info
ENV FINCEPT_PORT=8340
EXPOSE 8340

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:${FINCEPT_PORT}/health || exit 1

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/ac-fin_fincept-server/src/Dockerfile"

ENTRYPOINT ["/usr/local/bin/fincept-server"]
