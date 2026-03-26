FROM ghcr.io/diegonmarcos/octocode-fastembed-graphrag-indexed-arm:latest AS octocode

FROM ubuntu:24.04

WORKDIR /app

# Node.js 22 + build deps on Ubuntu 24.04 (glibc 2.39 matches octocode binary)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates python3 build-essential git libssl3 \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Octocode binary with fastembed — from our ARM GHCR image
# Index data comes from external named volume at runtime
COPY --from=octocode /usr/local/bin/octocode /usr/local/bin/octocode
RUN octocode --version

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY tsconfig.json ./
COPY index.ts config.ts context.ts ./
COPY tools/ ./tools/
COPY shared/ ./shared/

ENV MCP_TRANSPORT=http
ENV MCP_HTTP_PORT=3105

EXPOSE 3105

CMD ["npx", "tsx", "index.ts"]
