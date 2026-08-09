# rebuild 2026-08-09 (retry 3): queued as ONE commit — a separate push per service evicts the previously pending run from the ship-oci-apps group
# ship-cover 2026-08-09T18:40Z — single batched trigger: newest queued run must contain every undeployed oci-apps service (a newer pending run evicts older ones)
FROM node:22-bookworm-slim

WORKDIR /app

# System deps: SSH for remote VM commands, curl for healthcheck + API calls, ping for WG checks
# git for read-only repo clones (engines need source files)
# Build tools for better-sqlite3 (native module) — only needed if prebuilt binaries fail
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssh-client \
    iputils-ping \
    curl \
    git \
    python3 \
    build-essential \
    dnsutils \
    openssl \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Install npm dependencies (src/package.json is the Docker-context copy)
ENV PATH="/app/node_modules/.bin:$PATH"

COPY package.json ./
RUN npm install --omit=dev && npm install tsx

# Copy TypeScript config and source (context = src/)
COPY tsconfig.json ./
COPY shared/ ./src/shared/
COPY mcp/ ./src/mcp/

# Entrypoint: fix SSH keys, start MCP HTTP server
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

# SSH: known_hosts for host key verification
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

EXPOSE 3100

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:3100/mcp || exit 1

COPY Dockerfile /opt/cloud-builder/Dockerfile
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/bc-obs_c3-infra-mcp/src/Dockerfile"

ENTRYPOINT ["./entrypoint.sh"]
# rebuild 1774363117
