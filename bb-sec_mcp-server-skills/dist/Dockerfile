FROM node:22-bookworm-slim

WORKDIR /app

# System deps: SSH for remote VM commands, curl for API calls, git for repo search
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install npm dependencies
COPY package.json ./
RUN npm install

# Copy TypeScript config and source
COPY tsconfig.json ./
COPY src/ ./src/

# Type-check at build time
RUN npx tsc --noEmit

# Drop privileges — node:22 images include the 'node' user
USER node

# MCP stdio transport — no port exposed
CMD ["npx", "tsx", "src/index.ts"]
