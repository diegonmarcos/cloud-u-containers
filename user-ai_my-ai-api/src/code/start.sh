#!/usr/bin/env bash
# start.sh — supervise the my-ai-api processes in one container:
#   1. compress_service  (Python/FastAPI · vendored Headroom)  — must come up first
#   2. server.mjs        (Node front · OpenAI/Ollama/Anthropic → OpenRouter)
#   3. gateway.mjs       (Telegram + Mattermost → goose bridge, optional)
#
# Slimmer than claude-superset-api's start.sh: NO headroom transparent-proxy face
# (no `headroom proxy --backend anthropic` — we route OpenRouter, and the Node
# front forwards directly), NO claude-config sync (the agent is goose, which
# runs on the client, not in this container). The Headroom compression hop
# (compress_service.py) is kept — that is the tokens-optimization plugin.
#
# tini (compose init:true) is PID1 and reaps short-lived fetch children. This
# script is the foreground process: if EITHER service dies, kill the other and
# exit non-zero so the container stops (no auto-restart — recovery is a ship).
set -euo pipefail

HEADROOM_PORT="${HEADROOM_PORT:-8890}"

# Goose reads $XDG_CONFIG_HOME/goose/config.yaml. The Dockerfile bakes the config
# at /app/.config/goose/config.yaml and sets XDG_CONFIG_HOME=/app/.config (outside
# the /home/appuser volume, so it refreshes every deploy). Honour those; only fall
# back if unset.
export HOME="${HOME:-/home/appuser}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/app/.config}"

term() { echo "[start] shutting down"; kill "${PIDS[@]}" 2>/dev/null || true; }
trap term TERM INT

PIDS=()

echo "[start] launching compress_service on :${HEADROOM_PORT}"
python3 /app/py/compress_service.py &
PIDS+=("$!")

# Wait until the compressor answers /readyz (model/pipeline import can take a few s).
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${HEADROOM_PORT}/readyz" >/dev/null 2>&1; then
    echo "[start] compress_service ready (${i}s)"
    break
  fi
  if ! kill -0 "${PIDS[0]}" 2>/dev/null; then
    echo "[start] compress_service died during startup" >&2; exit 1
  fi
  sleep 1
done

echo "[start] launching node front"
node /app/server.mjs &
PIDS+=("$!")

# Gateway: only launch if at least one messaging platform is configured.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || [ "${MATTERMOST_ENABLED:-}" = "true" ]; then
  echo "[start] launching gateway (messaging bridge)"
  node /app/gateway.mjs &
  PIDS+=("$!")
else
  echo "[start] gateway: no messaging configured — skipping"
fi

# Supervise: first process to exit takes the container down with it.
wait -n
code=$?
echo "[start] a process exited (code=${code}); stopping siblings"
term
exit "${code:-1}"
