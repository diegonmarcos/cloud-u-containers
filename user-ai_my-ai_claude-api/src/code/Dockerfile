# claude-api-superset — polyglot image (Rust + Python + Node + claude CLI).
#
# Build context (assembled by engine.nix from flake nativeBuild.extraFiles):
#   ./vendor/headroom/   vendored Apache-2.0 Headroom source (maturin/pyo3 + Python)
#   ./py/                compress_service.py (FastAPI sidecar)
#   ./server.mjs         Node front (OpenAI/Ollama/Anthropic → claude CLI)
#   ./package.json
#   ./start.sh           process supervisor
#
# Built on the arm64 cloud-builder-x (oci-apps) — no QEMU. Stage 1 compiles the
# Headroom Rust core via maturin into a wheel; stage 2 is a slim Python+Node
# runtime. Adapted from upstream's own multi-stage Dockerfile (rustls, no openssl).

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

# ─── Stage 2: runtime (Python + Node + claude CLI) ───────────────────────────
FROM python:${PYTHON_VERSION}-slim AS runtime

ARG NODE_MAJOR=22
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/home/appuser

# Node (for server.mjs + the claude CLI) + curl (start.sh readiness probe) +
# jq (the c-* PreToolUse guard hooks parse the hook JSON with jq).
# bsdutils/util-linux provide `script`, which login.mjs uses to allocate a pty
# for `claude setup-token` (it refuses to run without a tty). Both are normally
# present in the slim base as Essential packages — named explicitly so an image
# rebuild can never silently drop the interactive-login path.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates jq bsdutils util-linux \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force \
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
COPY server.mjs login.mjs package.json /app/
COPY py/ /app/py/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh
# Claude parity config (hooks + ponytail + skills + CLAUDE.md + MCP template).
# Baked under /app (NOT ~/.claude): the claude_home volume mounts over the whole
# home and only seeds once, so start.sh re-syncs from here on every boot.
COPY claude-config /app/claude-config

# Non-root appuser; HOME holds the persisted Claude login + ~/.headroom ledger
# (mounted as the claude_home named volume at runtime).
RUN useradd -r -m -u 10001 appuser \
    && mkdir -p /home/appuser/.claude /home/appuser/.headroom \
    && chown -R appuser:appuser /home/appuser /app
USER appuser

EXPOSE 3117 11436 8788 8789
CMD ["/app/start.sh"]
