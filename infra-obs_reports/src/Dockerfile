FROM rust:1.88-slim-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
# All Rust sources live under src/ (workspace root).
COPY src/ /build/
RUN cargo build --release

FROM debian:bookworm-slim
# WireGuard stack: wireguard-tools provides wg/wg-quick; iproute2 provides ip
# (wg-quick shells out to it); iptables is required by wg-quick when
# AllowedIPs routes are split. jq is used by entrypoint.sh to derive
# ~/.ssh/config from cloud-data JSON.
# resolvconf is intentionally NOT installed — its postinst tries to symlink
# /etc/resolv.conf which is in-use during Docker buildkit and the install
# fails. Our AllowedIPs (10.0.0.0/24) does not push DNS, so wg-quick runs
# fine without it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates openssh-client curl dnsutils iputils-ping netcat-openbsd \
    openssl yara rsync jq \
    graphviz plantuml \
    wireguard-tools iproute2 iptables \
    && rm -rf /var/lib/apt/lists/*

# Install D2 (architecture diagrams) — binary release
RUN ARCH=$(dpkg --print-architecture) && \
    curl -sfL "https://github.com/terrastruct/d2/releases/latest/download/d2-linux-${ARCH}.tar.gz" | \
    tar xz -C /usr/local/bin --strip-components=1 --wildcards '*/d2' || true

# Install Pikchr (inline SVG diagrams) — pinned fossil tarball → make
# Source of truth: reports/build-deps.json (URL + sha256 + version hash).
COPY build-deps.json /tmp/build-deps.json
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev make jq && \
    URL=$(jq -r .pikchr.url /tmp/build-deps.json) && \
    SHA=$(jq -r .pikchr.sha256 /tmp/build-deps.json) && \
    DEST=$(jq -r .pikchr.install_path /tmp/build-deps.json) && \
    curl -fsSL "$URL" -o /tmp/pikchr.tar.gz && \
    echo "$SHA  /tmp/pikchr.tar.gz" | sha256sum -c - && \
    mkdir -p /tmp/pikchr-src && tar xzf /tmp/pikchr.tar.gz -C /tmp/pikchr-src --strip-components=1 && \
    (cd /tmp/pikchr-src && make pikchr) && \
    install -m 0755 /tmp/pikchr-src/pikchr "$DEST" && \
    rm -rf /tmp/pikchr-src /tmp/pikchr.tar.gz /tmp/build-deps.json && \
    apt-get purge -y gcc libc6-dev make && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
    # NOTE: jq is intentionally NOT purged here — entrypoint.sh needs it at
    # runtime to derive ~/.ssh/config from cloud-data JSON. Earlier builds
    # purged jq alongside the pikchr build deps, leaving the final image
    # without jq even though stage-1 had installed it.

# Fetch community YARA rules at build time
RUN mkdir -p /usr/local/share/yara-rules/community && \
    curl -sL https://urlhaus.abuse.ch/downloads/urlhaus.rules \
      -o /usr/local/share/yara-rules/community/urlhaus.yar || true

# Copy binaries (names match Cargo workspace members in src/Cargo.toml)
# Master: cloud-health-full-daily
# Derives: cloud-mail-health-full, cloud-url-health-report,
#          cloud-sec-network-report, cloud-sec-data-report
COPY --from=builder /build/target/release/cloud-health-full-daily /usr/local/bin/
COPY --from=builder /build/target/release/cloud-mail-health-full /usr/local/bin/
COPY --from=builder /build/target/release/cloud-url-health-report /usr/local/bin/
COPY --from=builder /build/target/release/cloud-sec-network /usr/local/bin/
COPY --from=builder /build/target/release/cloud-sec-data /usr/local/bin/

# Bundle YARA rules (custom + infra)
COPY src/cloud-sec-data-report/yara-rules/ /usr/local/share/yara-rules/

# Entrypoint — same pattern as cloud-builder-x
COPY entrypoint.sh /opt/reports/entrypoint.sh
RUN chmod +x /opt/reports/entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"
LABEL org.opencontainers.image.description="cloud-data-reports — health report runner (SSH, WG, SOPS setup). Source moved cloud-data/y_old/reports -> cloud-infra/a_solutions/infra-obs_reports 2026-08-19; report OUTPUT still publishes to cloud-data."

WORKDIR /root/git/cloud-infra/a_solutions/infra-obs_reports/src
ENTRYPOINT ["/opt/reports/entrypoint.sh"]
CMD ["all"]
