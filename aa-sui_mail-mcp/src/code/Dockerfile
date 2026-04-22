FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends dnsutils openssh-client && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY tsconfig.json ./
COPY mcp/ ./mcp/

COPY Dockerfile /opt/cloud-builder/Dockerfile
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/aa-sui_mail-mcp/src/Dockerfile"

CMD ["npx", "tsx", "mcp/index.ts", "--http"]
