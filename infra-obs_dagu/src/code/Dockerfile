# dagucloud/dagu:2.5.0 removes apk for hardening — cannot RUN apk on it.
# Multi-stage: pull only the dagu binary, install tooling on fresh Alpine.
FROM ghcr.io/dagucloud/dagu:2.5.0 AS dagu-src

FROM alpine:3.19
USER root

RUN apk add --no-cache \
    bash \
    openssh-client \
    curl \
    openssl \
    bind-tools \
    git \
    jq \
    docker-cli

COPY --from=dagu-src /usr/local/bin/dagu /usr/local/bin/dagu

# Install websocat (WebSocket CLI — ntfy bridge)
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) WS_ARCH="x86_64-unknown-linux-musl";; aarch64) WS_ARCH="aarch64-unknown-linux-musl";; esac && \
    curl -sfL "https://github.com/vi/websocat/releases/download/v1.14.0/websocat_max.${WS_ARCH}" -o /usr/local/bin/websocat && \
    chmod +x /usr/local/bin/websocat

# Install yq (YAML processor)
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) YQ_ARCH="amd64";; aarch64) YQ_ARCH="arm64";; esac && \
    curl -sfL "https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_${YQ_ARCH}" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Create dagu user (UID 1000 — compose mounts /home/dagu/.ssh)
RUN addgroup -g 1000 dagu && adduser -D -u 1000 -G dagu -h /home/dagu dagu

# Bake ONLY the static files. dags/, base.yaml and fetch-token.sh arrive via
# compose bind-mounts (see compose.nix volumes).
COPY triggers.json /etc/dagu/triggers.json
COPY ntfy-bridge.sh /usr/local/bin/ntfy-bridge.sh
RUN chmod +x /usr/local/bin/ntfy-bridge.sh

# Ensure dagu user can access SSH keys mounted from host
RUN mkdir -p /home/dagu/.ssh && chown -R dagu:dagu /home/dagu/.ssh

EXPOSE 8080
ENTRYPOINT ["dagu"]

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
