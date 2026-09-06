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

# ── Git identity + agent workspace ───────────────────────────────────────
# The token is delivered by the .secrets env_file (sops -> GH_TOKEN), never
# baked into the image. It is handed to git by a credential helper that reads
# $GH_TOKEN at call time, so the token never lands in .git/config or on the
# persistent volume.
# NEVER let workspace setup kill the container: this script runs under
# `set -e`, so an unguarded `git` call in an image without git exits PID1 and
# the service dies on boot. That is exactly what happened on the first deploy
# of this block (git was installed in the builder stage only), so every command
# here is guarded and non-fatal.
if command -v git >/dev/null 2>&1; then
  git config --global user.name  "Diego" || true
  git config --global user.email "me@diegonmarcos.com" || true
  git config --global credential.helper \
    '!f() { echo username=x-access-token; echo "password=${GH_TOKEN}"; }; f' || true
  git config --global --add safe.directory '*' || true
else
  echo "[start] WARN: git not installed; skipping git identity + repo bootstrap" >&2
fi

# Repos live in the persistent home volume, so clones survive redeploys.
#
# ORIGIN IS GITHUB, NOT GITEA — deliberate, do not "optimise" this to gitea:
#   The gitea repos at http://10.0.0.6:3002 are PULL-ONLY MIRRORS, resynced
#   from GitHub hourly. A push to a mirror is ACCEPTED and then DESTROYED on
#   the next sync. Pointing origin at gitea would hand agents a remote that
#   silently eats their work. So: READ-LOCAL / WRITE-UPSTREAM — origin is
#   always GitHub (pushable), and gitea is added as a separate `gitea` remote
#   for fast mesh-local fetches when you explicitly want them.
#   cloud-infra must clone from GitHub regardless: its .gitmodules pins
#   https://github.com/... URLs, so --recurse-submodules leaves the mesh anyway.
#   Ten gitea mirrors are EMPTY (private repos, no GITHUB_MIRROR_TOKEN) —
#   cloud-data, cloud-data-lfs, cloud-data-my-ai-memory, cloud-notes, dev,
#   front-galaxy-gaia, front-unity, lecole42, cloud-mykonsole-dtk, cloud-vault.
#   Those can ONLY come from GitHub.
bootstrap_repos() {
  mkdir -p "${HOME}/git"
  cd "${HOME}/git" || return 0
  for repo in cloud-infra cloud-u-containers cloud-u-android cloud-u-linux; do
    if [ -d "${repo}/.git" ]; then
      echo "[bootstrap] ${repo} already present; leaving it alone" >&2
      continue
    fi
    echo "[bootstrap] cloning ${repo} from GitHub" >&2
    # cloud-infra without --recurse-submodules leaves a_solutions empty and the
    # tree structurally broken (the build-*.json symlinks all dangle).
    extra=""
    [ "${repo}" = "cloud-infra" ] && extra="--recurse-submodules"
    # shellcheck disable=SC2086
    if git clone ${extra} "https://github.com/diegonmarcos/${repo}.git" "${repo}"; then
      git -C "${repo}" remote add gitea "http://10.0.0.6:3002/diego/${repo}.git" 2>/dev/null || true
      # Belt and braces: even if someone runs `git push gitea`, refuse it.
      git -C "${repo}" remote set-url --push gitea DISABLED_pull_only_mirror
    else
      echo "[bootstrap] WARN: ${repo} clone failed; continuing" >&2
    fi
  done
  echo "[bootstrap] done" >&2
}

if [ -n "${GH_TOKEN:-}" ] && command -v git >/dev/null 2>&1; then
  # Detached from the job table on purpose: the supervisor below uses `wait -n`,
  # and an un-disowned background job completing would satisfy that wait and
  # take the whole container down.
  bootstrap_repos &
  disown $! 2>/dev/null || true
else
  echo "[start] GH_TOKEN unset; skipping repo bootstrap (agents will have no repos)" >&2
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
# Wait on the SERVICE pids explicitly — a bare `wait -n` returns for any
# background job, so an unrelated helper finishing would stop the container.
wait -n "${PIDS[@]}"
code=$?
echo "[start] a process exited (code=${code}); stopping siblings"
term
exit "${code:-1}"
