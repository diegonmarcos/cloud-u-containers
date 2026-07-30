#!/usr/bin/env bash
# start.sh — supervise the my-ai-api processes in one container:
#   1. compress_service  (Python/FastAPI · vendored Headroom)  — best-effort sidecar
#   2. goosed            (goose serve ACP agent, optional)     — best-effort sidecar
#   3. gateway.mjs       (Telegram + Mattermost → goose bridge, optional) — best-effort
#   4. server.mjs        (Node front · core HTTP API :3217)    — lifecycle process
#
# Slimmer than claude-superset-api's start.sh: NO headroom transparent-proxy face
# (no `headroom proxy --backend anthropic` — we route OpenRouter, and the Node
# front forwards directly), NO claude-config sync (the agent is goose, which
# runs on the client, not in this container). The Headroom compression hop
# (compress_service.py) is kept — that is the tokens-optimization plugin.
#
# tini (compose init:true) is PID1 and reaps short-lived fetch children. This
# script execs server.mjs as the final foreground process: the container lives
# and dies only with the core API on :3217. The three sidecars are best-effort
# background jobs — their failure is logged but never takes the container down.
set -euo pipefail

HEADROOM_PORT="${HEADROOM_PORT:-8890}"
GOOSE_PORT="${GOOSE_PORT:-3227}"

# Goose reads $XDG_CONFIG_HOME/goose/config.yaml. The Dockerfile bakes the config
# at /app/.config/goose/config.yaml and sets XDG_CONFIG_HOME=/app/.config (outside
# the /home/appuser volume, so it refreshes every deploy). Honour those; only fall
# back if unset.
export HOME="${HOME:-/home/appuser}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/app/.config}"

# Sidecar: compress_service (Headroom tokens-optimization plugin, :HEADROOM_PORT).
# Best-effort — if it exits for any reason, log and continue.
echo "[start] launching compress_service on :${HEADROOM_PORT}"
( python3 /app/py/compress_service.py || echo "[compress_service] exited — sidecar down, container continues" ) &

# Wait until the compressor answers /readyz (model/pipeline import can take a few s).
# If it never comes up, log a warning but do not abort — server.mjs still starts.
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${HEADROOM_PORT}/readyz" >/dev/null 2>&1; then
    echo "[start] compress_service ready (${i}s)"
    break
  fi
  if [ "${i}" -eq 60 ]; then
    echo "[start] compress_service did not become ready in 60s — continuing without it" >&2
  fi
  sleep 1
done

# Sidecar: goosed (ACP remote-agent server).
# Only launch if the secret key is set. Wrapped so that if `goose serve` is an
# unsupported subcommand in this build, the container is not affected.
if [ -n "${GOOSE_SERVER__SECRET_KEY:-}" ]; then
  echo "[goosed] serving on :${GOOSE_PORT} (ACP, X-Secret-Key)"
  ( goose serve --platform desktop --enable-scheduler --host 0.0.0.0 --port "${GOOSE_PORT}" \
      || echo "[goosed] serve unavailable — remote agent disabled, container continues" ) &
else
  echo "[goosed] no secret key — skipping"
fi

# Sidecar: gateway.mjs (messaging bridge).
# Only launch if at least one messaging platform is configured.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || [ "${MATTERMOST_ENABLED:-}" = "true" ]; then
  echo "[start] launching gateway (messaging bridge)"
  ( node /app/gateway.mjs || echo "[gateway] exited — messaging bridge down, container continues" ) &
else
  echo "[start] gateway: no messaging configured — skipping"
fi

# Core API: server.mjs is the sole lifecycle process.
# exec replaces this shell; the container exits only when server.mjs exits.
echo "[start] launching server.mjs (core API :3217)"
exec node /app/server.mjs
