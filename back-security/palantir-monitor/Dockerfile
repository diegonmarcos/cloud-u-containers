# Multi-stage build for Rust-based Palantir Monitor

# Stage 1: Build
FROM rustlang/rust:nightly-bookworm as builder

WORKDIR /build

# Copy dependency manifests
COPY Cargo.toml ./

# Copy source code
COPY src ./src
COPY templates ./templates

# Build release binary
RUN cargo build --release --bin palantir-monitor

# Stage 2: Runtime
FROM debian:bookworm-slim

# Install only necessary runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /app/reports /app/config /root/.ssh && \
    chmod 700 /root/.ssh

WORKDIR /app

# Copy compiled binary from builder
COPY --from=builder /build/target/release/palantir-monitor /app/palantir-monitor

# Copy configuration and templates
COPY config /app/config
COPY templates /app/templates

# Make binary executable
RUN chmod +x /app/palantir-monitor

# Entrypoint
ENTRYPOINT ["/app/palantir-monitor"]
