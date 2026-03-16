FROM node:22-bookworm-slim

WORKDIR /app

# System deps: curl for healthcheck + API proxying
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install npm dependencies
COPY package.json ./
RUN npm install --omit=dev && npm install tsx

# Copy TypeScript config and source (context = src/)
COPY tsconfig.json ./
COPY shared/ ./src/shared/
COPY registry/ ./src/registry/
COPY api/ ./src/api/
COPY mcp/ ./src/mcp/

# Entrypoint
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 8080
EXPOSE 3101

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["./entrypoint.sh"]
