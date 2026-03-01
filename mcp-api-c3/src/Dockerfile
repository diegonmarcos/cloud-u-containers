FROM node:22-bookworm-slim

WORKDIR /app

# System deps: SSH for remote VM commands, curl for healthcheck + API calls, ping for WG checks
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    iputils-ping \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install npm dependencies (src/package.json is the Docker-context copy)
COPY package.json ./
RUN npm install --omit=dev && npm install tsx

# Copy TypeScript config and source (context = src/)
COPY tsconfig.json ./
COPY shared/ ./src/shared/
COPY api/ ./src/api/

# SSH: known_hosts for host key verification
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["npx", "tsx", "src/api/index.ts"]
