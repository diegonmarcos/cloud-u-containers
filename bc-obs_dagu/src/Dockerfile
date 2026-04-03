FROM ghcr.io/dagu-org/dagu:1.30.3

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    curl \
    openssl \
    dnsutils \
    git \
    jq \
    yq \
    && rm -rf /var/lib/apt/lists/*

# Install websocat (WebSocket CLI — ntfy bridge)
RUN ARCH=$(uname -m) && \
    case "$ARCH" in x86_64) WS_ARCH="x86_64-unknown-linux-musl";; aarch64) WS_ARCH="aarch64-unknown-linux-musl";; esac && \
    curl -sfL "https://github.com/vi/websocat/releases/download/v1.14.0/websocat.${WS_ARCH}" -o /usr/local/bin/websocat && \
    chmod +x /usr/local/bin/websocat

# Bake config files into image (no bind mounts needed)
COPY dags /var/lib/dagu/dags
COPY base.yaml /var/lib/dagu/base.yaml
COPY fetch-token.sh /var/lib/dagu/fetch-token.sh
COPY triggers.json /etc/dagu/triggers.json
COPY ntfy-bridge.sh /usr/local/bin/ntfy-bridge.sh
RUN chmod +x /usr/local/bin/ntfy-bridge.sh

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
