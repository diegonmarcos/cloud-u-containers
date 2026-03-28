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

# Bake config files into image (no bind mounts needed)
COPY dags /var/lib/dagu/dags
COPY base.yaml /var/lib/dagu/base.yaml
COPY fetch-token.sh /var/lib/dagu/fetch-token.sh

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
