# Cloud Webmail — Type A own image.
# Multi-stage build of the VENDORED Bulwark webmail source
# (bulwarkmail/webmail @ 1.9.2, commit 2f1192bb3285dea2c8b8ece461d52967fe0e6706)
# that lives in ./webapp/ (engine copies it into the build context via
# nativeBuild.extraFiles). Build context = dist/code/arm64/, so all COPY paths
# are relative to webapp/. Mirrors Bulwark's own Dockerfile (Next.js 16 +
# React 19, standalone output, `next build --webpack`, node:24-alpine).
FROM node:24-alpine AS builder
WORKDIR /app
COPY webapp/package.json webapp/package-lock.json ./
RUN npm ci
COPY webapp/ ./
ENV NEXT_TELEMETRY_DISABLED=1
# Commit SHA shown in the About screen. We vendor source without .git, so
# next.config.ts's `git rev-parse` fallback can't run — pass the pin explicitly.
ARG GIT_COMMIT=2f1192b
ENV GIT_COMMIT=$GIT_COMMIT
# Bulwark's package.json build script uses --turbopack, but its Dockerfile
# pins --webpack for the production image; match that.
RUN npx next build --webpack

FROM node:24-alpine AS runner
LABEL org.opencontainers.image.title="Cloud Webmail"
LABEL org.opencontainers.image.description="Cloud Webmail — Stalwart-native JMAP webmail (build of bulwarkmail/webmail)"
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL cloud.diegonmarcos.upstream="bulwarkmail/webmail@1.9.2"
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
RUN apk upgrade --no-cache && \
    npm uninstall -g npm && \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npx && \
    addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
# Writable state dirs (settings sync, admin config/state, telemetry) — the app
# writes here at runtime; create + own them for the unprivileged user.
RUN mkdir -p /app/data/settings /app/data/admin /app/data/admin-state /app/data/telemetry && \
    chown -R nextjs:nodejs /app/data
USER nextjs
EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]
