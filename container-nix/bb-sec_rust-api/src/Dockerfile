# Stage 1: Build
FROM rust:1.84-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY src/ .
RUN cargo build --release

# Stage 2: Runtime
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    curl \
    iputils-ping \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/target/release/rust-api /app/rust-api

RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

ENV RUST_API_PORT=8080
ENV RUST_LOG=rust_api=info

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=5s \
    CMD curl -f http://localhost:8080/rust/health || exit 1

CMD ["/app/rust-api"]
