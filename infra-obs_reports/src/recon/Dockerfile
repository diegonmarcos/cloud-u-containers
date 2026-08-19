# External friend-hack recon image — the Kali/pentest-tool layer of
# cloud-security.yml. Runs ONLY from the external GHA vantage (amd64); never on a
# VM, never in the mesh. NO QEMU — single-arch amd64 is all that's needed.
#
# Core tools (must install): nmap, gitleaks, dnsutils, jq.
# ProjectDiscovery + TLS tools (best-effort — Kali package names drift; recon.sh
# checks `command -v` per tool and skips any that are absent, so a rename here
# degrades a stage instead of breaking the build).
FROM kalilinux/kali-rolling

ENV DEBIAN_FRONTEND=noninteractive

# Core (required)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nmap dnsutils gitleaks jq curl ca-certificates bash coreutils git \
 && rm -rf /var/lib/apt/lists/*

# ProjectDiscovery + TLS auditing (best-effort; never fail the build)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      nuclei dnsx httpx-toolkit testssl.sh \
    || echo "[recon-image] some PD/TLS tools unavailable via apt — recon.sh will skip them" \
 ; rm -rf /var/lib/apt/lists/* || true

# Pre-pull nuclei templates (offline-safe: never fail the build if the net is unavailable)
RUN command -v nuclei >/dev/null 2>&1 && nuclei -update-templates >/dev/null 2>&1 || true

COPY recon.sh /usr/local/bin/recon.sh
RUN chmod +x /usr/local/bin/recon.sh

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-data"
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/recon.sh"]
