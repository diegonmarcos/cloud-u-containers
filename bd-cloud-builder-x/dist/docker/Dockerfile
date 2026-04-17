# ╔══════════════════════════════════════════════════════════════════╗
# ║ cloud-builder — Self-contained CI/CD builder image              ║
# ║                                                                  ║
# ║ Contains: nix + devShell (sops, rsync, ssh, git, jq, yq, node)  ║
# ║           + docker CLI (for docker compose build --push)         ║
# ║           + all repos baked under ~/git/ (entrypoint rebases)    ║
# ║                                                                  ║
# ║ Source: unix/cb_containers-builders/src/docker/Dockerfile       ║
# ║ Registry: ghcr.io/diegonmarcos/cloud-builder-x-deb-nixhm       ║
# ╚══════════════════════════════════════════════════════════════════╝

# NIX_SYSTEM: x86_64-linux or aarch64-linux (set by GHA matrix)
ARG NIX_SYSTEM=x86_64-linux

FROM nixos/nix:latest AS builder

ARG NIX_SYSTEM

# Enable flakes
RUN mkdir -p /etc/nix && echo "experimental-features = nix-command flakes" > /etc/nix/nix.conf

# Copy cloud-builder flake (context is workflows/src/cloud-builder/)
WORKDIR /build
COPY flake.nix flake.lock ./

# Fetch config.json from GitHub (same as flake input does)
RUN nix flake update config-json --flake .

# Build the devShell — populates nix store with all deps
RUN nix build ".#devShells.${NIX_SYSTEM}.default.inputDerivation" --no-link

# Also pre-populate nixpkgs evaluations for faster service builds
RUN nix eval --json ".#devShells.${NIX_SYSTEM}.default.name" > /dev/null

# Install npm packages to /root/.node_modules (shared node deps)
RUN nix develop .# --command bash -c '\
    mkdir -p /root/.node_modules && \
    cd /root/.node_modules && \
    npm install --silent tsx yaml nunjucks 2>/dev/null && \
    echo "Node modules installed: $(ls node_modules | wc -l) packages"'

# ── Final image: nix store + node_modules + docker CLI ready ──
FROM nixos/nix:latest

RUN mkdir -p /etc/nix && echo "experimental-features = nix-command flakes" > /etc/nix/nix.conf

# Copy populated nix store from builder (devShell + npm deps)
COPY --from=builder /nix/store /nix/store
COPY --from=builder /nix/var /nix/var

# Install Docker CLI AFTER nix store copy (otherwise COPY overwrites it)
RUN nix profile install nixpkgs#docker-client nixpkgs#docker-compose

# Copy node_modules
COPY --from=builder /root/.node_modules /root/.node_modules

# Copy cloud-builder flake for nix develop at runtime
COPY --from=builder /build /opt/cloud-builder-flake

# ── Clone all repos under ~/git/ (HTTPS, public) ────────────────
RUN mkdir -p /root/git && \
    for repo in cloud cloud-data unix front tools; do \
      git clone --depth 1 "https://github.com/diegonmarcos/${repo}.git" "/root/git/${repo}"; \
    done && \
    git -C /root/git/cloud submodule update --init --recursive 2>/dev/null || true

# Self-documenting: all docker/ scripts baked into image
COPY docker/ /opt/cloud-builder/
RUN chmod +x /opt/cloud-builder/entrypoint.sh /opt/cloud-builder/docker-up.sh

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.description="cloud-builder — self-contained CI/CD image (nix, sops, rsync, docker, all repos)"

# Entrypoint: no args = print usage, anything else = dispatch command
WORKDIR /root/git/cloud
ENTRYPOINT ["/opt/cloud-builder/entrypoint.sh"]
CMD []
