FROM node:22-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 build-essential \
    && rm -rf /var/lib/apt/lists/*

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
