FROM golang:1.21-bookworm AS builder
RUN apt-get update && apt-get install -y gcc libc6-dev
WORKDIR /build
RUN git clone https://github.com/benbjohnson/postlite.git .
RUN CGO_ENABLED=1 go build -tags vtable -o postlite ./cmd/postlite

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/postlite /usr/local/bin/postlite
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"

EXPOSE 5432
ENTRYPOINT ["postlite"]
