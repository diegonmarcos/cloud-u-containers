FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY tsconfig.json ./
COPY mcp/ ./mcp/

CMD ["npx", "tsx", "mcp/index.ts", "--http"]
