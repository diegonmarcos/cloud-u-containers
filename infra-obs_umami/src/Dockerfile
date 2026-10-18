# Umami wrapper, multi-stage. The upstream image ships its build-time pnpm
# content store (/root/.local/share/pnpm), which is cache bloat. It also contains
# copies of third-party docs with sample private keys that trip ghcr-secret-scan.
# A RUN rm in a wrapping layer would only hide it, so the final stage copies the
# pruned filesystem onto scratch and restores the upstream runtime config.
FROM ghcr.io/umami-software/umami:latest AS upstream
USER root
RUN rm -rf /root/.local/share/pnpm /root/.cache/pnpm /root/.npm

FROM scratch
COPY --from=upstream / /
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL cloud.diegonmarcos.from-image="ghcr.io/umami-software/umami:latest"
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NODE_VERSION=22.23.2 \
    YARN_VERSION=1.22.22 \
    NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    NODE_OPTIONS= \
    HOSTNAME=0.0.0.0 \
    PORT=3000
WORKDIR /app
USER nextjs
EXPOSE 3000
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["sh", "scripts/start-docker.sh"]
