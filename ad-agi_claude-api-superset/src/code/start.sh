#!/usr/bin/env bash
# start.sh — supervise the two superset processes in one container:
#   1. compress_service  (Python/FastAPI · vendored Headroom)  — must come up first
#   2. server.mjs        (Node front · OpenAI/Ollama/Anthropic → claude CLI)
#
# tini (compose init:true) is PID1 and reaps the short-lived `claude -p` children.
# This script is the foreground process: if EITHER service dies, kill the other
# and exit non-zero so the container stops (no auto-restart — recovery is a ship).
set -euo pipefail

HEADROOM_PORT="${HEADROOM_PORT:-8787}"

# Claude parity config: re-sync hooks/skills/CLAUDE.md/ponytail from the image and
# render the HTTP MCP servers on every boot. The claude_home volume mounts over the
# whole home and seeds from the image only once, so baked ~/.claude files would never
# update — syncing here makes redeploys propagate. Never touches ~/.claude.json's login.
CLAUDE_DIR="${HOME}/.claude"
mkdir -p "${CLAUDE_DIR}/skills"
cp -rf /app/claude-config/CLAUDE.md /app/claude-config/settings.json \
       /app/claude-config/hooks /app/claude-config/ponytail "${CLAUDE_DIR}/"
cp -rf /app/claude-config/skills/. "${CLAUDE_DIR}/skills/"
chmod +x "${CLAUDE_DIR}"/hooks/*.sh 2>/dev/null || true
if [ -n "${AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN:-}" ]; then
  node /app/claude-config/render-mcp.mjs || echo "[start] WARN: MCP render failed; continuing" >&2
else
  echo "[start] AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN unset; skipping MCP servers" >&2
fi

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

# Headroom proxy face (optional): the interactive ANTHROPIC_BASE_URL target.
# Compresses then forwards to Anthropic with the CLIENT's own creds (transparent),
# so a local `claude` keeps full multi-turn/tool behaviour. WG-bound (never 0.0.0.0).
if [ "${HEADROOM_PROXY_ENABLED:-1}" = "1" ]; then
  PROXY_PORT="${HEADROOM_PROXY_PORT:-8789}"
  PROXY_BIND="${HEADROOM_PROXY_BIND:-127.0.0.1}"
  PROXY_BACKEND="${HEADROOM_PROXY_BACKEND:-anthropic}"
  echo "[start] launching headroom proxy on ${PROXY_BIND}:${PROXY_PORT} (backend=${PROXY_BACKEND})"
  headroom proxy --host "$PROXY_BIND" --port "$PROXY_PORT" --backend "$PROXY_BACKEND" &
  PIDS+=("$!")
fi

echo "[start] launching node front"
node /app/server.mjs &
PIDS+=("$!")

# Supervise: first process to exit takes the container down with it.
wait -n
code=$?
echo "[start] a process exited (code=${code}); stopping siblings"
term
exit "${code:-1}"
