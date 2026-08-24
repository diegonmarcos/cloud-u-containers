# rebuild 2026-08-09: shared/ out-of-context symlink fix (materialize_out_of_context_symlinks in cloud-ship-container-step-build-docker.sh)
FROM node:22-bookworm-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY package.json ./
RUN npm install --omit=dev && npm install tsx

COPY tsconfig.json ./
COPY shared/ ./src/shared/
COPY mcp/ ./src/mcp/
COPY registry/ ./src/registry/

# `--chmod=0755` bakes the perm bit into the COPY layer's content hash so
# --cache-from can't resurrect a stale layer where chmod hadn't been
# applied yet (which is exactly what bit us 2026-04-28 after step_docker
# started using --cache-from: tini exec ./entrypoint.sh failed:
# Permission denied even though `RUN chmod +x` followed the COPY).
COPY --chmod=0755 entrypoint.sh ./

EXPOSE 3101

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:3101/mcp || exit 1

COPY Dockerfile /opt/cloud-builder/Dockerfile
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/bc-obs_c3-services-mcp/src/Dockerfile"

ENTRYPOINT ["./entrypoint.sh"]
# rebuild 1775368117
