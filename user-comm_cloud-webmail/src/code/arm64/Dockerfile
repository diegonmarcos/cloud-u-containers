# Cloud Webmail — Type A own image.
# Multi-stage build of the VENDORED, rebranded root-fr/jmap-webmail source
# (v1.7.1, commit d682f5fe238545f34c93947797ad8548ae4d55be) that lives in
# ./webapp/ (engine copies it into the build context via nativeBuild.extraFiles).
# Build context = dist/code/arm64/, so all COPY paths are relative to webapp/.
FROM node:24-alpine AS builder
WORKDIR /app
COPY webapp/package.json webapp/package-lock.json ./
RUN npm ci
COPY webapp/ ./
ENV NEXT_TELEMETRY_DISABLED=1
RUN npx next build --webpack

FROM node:24-alpine AS runner
LABEL org.opencontainers.image.title="Cloud Webmail"
LABEL org.opencontainers.image.description="Cloud Webmail — JMAP webmail client (rebrand of root-fr/jmap-webmail)"
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.licenses="MIT"
LABEL cloud.diegonmarcos.upstream="root-fr/jmap-webmail@v1.7.1"
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
USER nextjs
EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]
