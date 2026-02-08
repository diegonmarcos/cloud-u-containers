FROM debian:bookworm-slim

# Lightweight tools - NO heavy CLIs (OCI/GCloud)
# Uses SSH + curl APIs instead for ~30MB RAM vs ~400MB
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    bc \
    netcat-openbsd \
    dnsutils \
    openssl \
    openssh-client \
    swaks \
    ca-certificates \
    libnet-ssleay-perl \
    libio-socket-ssl-perl \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /app/scripts /app/reports /app/config /root/.ssh && \
    chmod 700 /root/.ssh

# Copy scripts and entrypoint
COPY scripts/ /app/scripts/
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/scripts/*.sh /app/entrypoint.sh

WORKDIR /app

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/app/scripts/run-checks.sh"]
