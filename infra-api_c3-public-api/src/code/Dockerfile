FROM node:22-bookworm-slim

WORKDIR /app

# Lean runtime: curl for healthcheck + outbound checks, ca-certs for TLS.
# (No SSH, no build tools — this is a pure listener with HTTP-out + SMTP-out.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install npm deps + tsx (we run TS directly via tsx for parity with the
# c3-infra-api / c3-analytics-api template — no compile step needed).
COPY package.json ./
RUN npm install --omit=dev && npm install tsx

COPY tsconfig.json ./
COPY shared/ ./shared/
COPY api/ ./api/

COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 8087

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8087/health || exit 1

COPY Dockerfile /opt/cloud-builder/Dockerfile
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/bc-obs_c3-public-api/src/Dockerfile"

ENTRYPOINT ["./entrypoint.sh"]
