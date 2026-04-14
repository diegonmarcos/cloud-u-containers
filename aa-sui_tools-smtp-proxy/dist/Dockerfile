FROM rust:1.83-slim-bookworm AS builder
WORKDIR /app
COPY Cargo.toml main.rs ./
ENV CARGO_BUILD_JOBS=2
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/smtp-proxy /usr/local/bin/
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
EXPOSE 8080
CMD ["smtp-proxy"]
