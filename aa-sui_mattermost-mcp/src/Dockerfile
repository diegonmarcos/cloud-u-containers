FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY tsconfig.json ./
COPY *.ts ./

CMD ["npx", "tsx", "index.ts", "--http"]
