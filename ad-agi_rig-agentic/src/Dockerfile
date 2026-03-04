# syntax=docker/dockerfile:1
# Stage 1: Build (aarch64, on-VM via REMOTE_BUILD)
FROM rust:latest AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY src/ src/

RUN --mount=type=cache,target=/build/target \
    --mount=type=cache,target=/usr/local/cargo/registry \
    cargo build --release --jobs 2 && \
    cp /build/target/release/rig-agentic /build/rig-agentic-binary

# Stage 2: Runtime
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates docker.io \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/rig-agentic-binary /app/rig-agentic

RUN useradd -m -u 1000 -G docker appuser && chown -R appuser:appuser /app
USER appuser

ENV RIG_PORT=8090
ENV RUST_LOG=rig_agentic=info

EXPOSE 8090

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=15s \
    CMD curl -sf http://localhost:8090/health || exit 1

CMD ["/app/rig-agentic"]
