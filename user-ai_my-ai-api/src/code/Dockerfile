# my-ai-api — polyglot image (Python Headroom sidecar + Node front).
#
# Sibling of claude-superset-api. Routes to three agent backends (OpenRouter,
# claude-superset-api WG, goose binary) with a plugin pipeline:
#   RTK     — ANSI stripping + tool-result truncation (Node, RTK_ENABLED=1)
#   Caveman — assistant filler-phrase stripping (Python sidecar, CAVEMAN_ENABLED=1)
#   Ponytail— per-request savings profile (X-Ponytail-Mode: off|lite|full|ultra)
#   Headroom— token compression via vendored Rust core (Python sidecar)
#
# Build context (assembled by engine.nix from flake nativeBuild.extraFiles):
#   ./vendor/headroom/   vendored Apache-2.0 Headroom source (maturin/pyo3 + Python)
#   ./py/                compress_service.py (FastAPI sidecar)
#   ./server.mjs         Node front (OpenAI/Ollama/Anthropic → multi-backend)
#   ./package.json
#   ./start.sh           process supervisor
#
# Built on the arm64 cloud-builder-x (oci-apps) — no QEMU. Stage 1 compiles the
# Headroom Rust core via maturin into a wheel; stage 2 is a slim Python+Node
# runtime. Adapted from claude-superset-api's multi-stage Dockerfile (rustls,
# no openssl).

ARG PYTHON_VERSION=3.13

# ─── Stage 1: build the Headroom wheel (Rust core via maturin) ───────────────
FROM python:${PYTHON_VERSION}-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential g++ curl ca-certificates patchelf git \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir uv

# Rust toolchain (pinned to match vendor/headroom/rust-toolchain.toml = 1.95.0).
ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:${PATH}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain 1.95.0

WORKDIR /build
# Vendored Headroom source (pyproject.toml + Cargo workspace + crates + python).
COPY vendor/headroom/ /build/

# Build + install the wheel with the proxy (FastAPI/uvicorn — used by the sidecar)
# and code (AST CodeCompressor) extras. ML extras are intentionally omitted on arm64.
RUN uv pip install --system ".[proxy,code]"

# Fail-loud smoke check: the Rust core must import before we ship.
RUN cd /tmp && python -c "from headroom._core import SmartCrusher; from headroom import compress; print('headroom core OK')"

# ─── Stage 2: runtime (Python + Node) ────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim AS runtime

ARG NODE_MAJOR=22
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/home/appuser \
    RTK_ENABLED=1 \
    CAVEMAN_ENABLED=1 \
    PONYTAIL_DEFAULT_MODE=full \
    AGENTS_PRINCIPLES_ENABLED=1 \
    CLOUD_PRINCIPLES_ENABLED=1

# Node (for server.mjs) + curl (start.sh readiness probe) + git.
#
# git is NOT incidental here. This image mounts the shared checkout and runs
# goose from inside it (see start.sh), which only makes sense if the agent can
# commit and push what it changes. The runtime stage had no git at all — only
# the discarded builder stage did — so goose could open every file in six
# repositories and not run a single git command: `git: not found`. That reads
# as "the agent chose not to commit" rather than "the agent cannot", which is
# why it went unnoticed while the tree looked correctly mounted.
# Also install goose (Block) — the container ships a preconfigured agent so it
# is self-contained: `docker exec -it my-ai-api goose session` works out of the
# box, pointed at OpenRouter via the container's OPENROUTER_API_KEY (sops-decrypted
# at ship time). goose is downloaded as a static binary for the target arch.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && ARCH="$(uname -m)" \
    && case "$ARCH" in \
         aarch64|arm64) GOOSE_ARCH="aarch64-unknown-linux-gnu" ;; \
         x86_64|amd64)  GOOSE_ARCH="x86_64-unknown-linux-gnu"  ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && GOOSE_VER="1.44.0" \
    && curl -fsSL "https://github.com/block/goose/releases/download/v${GOOSE_VER}/goose-${GOOSE_ARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin ./goose \
    && chmod +x /usr/local/bin/goose \
    && goose --version \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

# Agent toolbelt. Same reasoning as git above: the agent that runs in this image
# is expected to search a six-repository checkout, edit it, commit, push, and then
# prove its own CI went green. Every tool below was MISSING and each absence
# degraded silently rather than erroring usefully.
#
# gh is the one that mattered most (#366). With no `gh`, an agent told to "watch
# your CI to green" runs `gh run view`, gets `gh: not found`, and reports green
# having checked nothing — the failure looks identical to success. gh is not in
# Debian's repositories, so it comes from the upstream release tarball, arch-aware
# like goose above.
#
# jq / ripgrep / yq: an agent without them falls back to grep and hand-rolled
# string slicing over JSON and YAML, which is where silently-wrong answers come
# from. patch / unzip / wget / procps: ordinary build-and-inspect plumbing.
# make / gcc: several testers in the fleet shell out to them. openssh-client and
# netcat-openbsd: reaching the mesh and probing a port.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         jq ripgrep patch unzip wget procps make gcc openssh-client netcat-openbsd \
    && ARCH="$(uname -m)" \
    && case "$ARCH" in \
         aarch64|arm64) GH_ARCH="arm64" ;; \
         x86_64|amd64)  GH_ARCH="amd64" ;; \
         *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
       esac \
    && GH_VER="2.63.2" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_${GH_ARCH}.tar.gz" \
       | tar -xz -C /tmp \
    && install -m 0755 "/tmp/gh_${GH_VER}_linux_${GH_ARCH}/bin/gh" /usr/local/bin/gh \
    && rm -rf "/tmp/gh_${GH_VER}_linux_${GH_ARCH}" \
    && YQ_VER="4.44.6" \
    && curl -fsSL -o /usr/local/bin/yq \
         "https://github.com/mikefarah/yq/releases/download/v${YQ_VER}/yq_linux_${GH_ARCH}" \
    && chmod +x /usr/local/bin/yq \
    && gh --version && yq --version && jq --version && rg --version \
    && rm -rf /var/lib/apt/lists/*

# Python runtime: the installed site-packages (headroom + _core.so + deps) and
# the `headroom` console script, copied from the builder.
# NOTE: CPython's lib dir is major.minor (python3.13) regardless of the patch
# release — and the cloud-builder injects PYTHON_VERSION as the full patch
# (e.g. 3.13.14), so ${PYTHON_VERSION} must NOT be used in this path. Pin
# major.minor to match the `python:3.13-slim` base tag above.
COPY --from=builder /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages
COPY --from=builder /usr/local/bin/headroom /usr/local/bin/headroom

# App code.
WORKDIR /app
COPY server.mjs mcp.mjs package.json /app/
COPY gateway.mjs /app/gateway.mjs
COPY bots.json /app/bots.json
COPY bots/ /app/bots/
COPY py/ /app/py/
COPY start.sh /app/start.sh
COPY principles/ /app/principles/
RUN chmod +x /app/start.sh

# Non-root appuser; HOME holds the persisted session store + ~/.headroom ledger
# (mounted as the my_ai_home named volume at runtime).
# The goose config lives under /app/.config (XDG_CONFIG_HOME), NOT under
# /home/appuser — the my_ai_home:/home/appuser volume would otherwise shadow it
# and pin whatever config landed on first boot, so config edits would never
# propagate on redeploy. Keeping it in the image layer at /app makes goose read
# the freshly-built config every deploy while sessions/headroom persist in the volume.
RUN useradd -r -m -u 10001 appuser \
    && mkdir -p /home/appuser/.headroom \
    && mkdir -p /app/.config/goose \
    && chown -R appuser:appuser /home/appuser /app
COPY configs/goose-config.yaml /app/.config/goose/config.yaml
RUN chown appuser:appuser /app/.config/goose/config.yaml

ENV HOME=/home/appuser \
    XDG_CONFIG_HOME=/app/.config

USER appuser

EXPOSE 3217 12436 8890
CMD ["/app/start.sh"]
