#!/bin/sh
# C3-API entrypoint: clone repos, generate topology, start server
set -e

REPOS_DIR="${GIT_BASE:-/app/repos}"

# Clone/pull repos — C3-API is self-contained, generates its own config
SSH_KEY="$(ls /root/.ssh/id_rsa /root/.ssh/vault_id_rsa /root/.ssh/id_ed25519 2>/dev/null | head -1)"
if [ -n "$SSH_KEY" ]; then
  export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o StrictHostKeyChecking=no"
  echo "c3-entrypoint: syncing repos to $REPOS_DIR..."
  for repo in cloud unix front; do
    dir="$REPOS_DIR/$repo"
    if [ -d "$dir/.git" ]; then
      echo "  $repo: pulling..."
      git -C "$dir" fetch --all --quiet 2>/dev/null && \
        git -C "$dir" reset --hard origin/main --quiet 2>/dev/null || \
        echo "  $repo: fetch failed (non-fatal)"
    else
      echo "  $repo: cloning..."
      mkdir -p "$dir"
      git clone --depth 1 --single-branch --branch main \
        git@github.com:diegonmarcos/$repo.git "$dir" 2>/dev/null || \
        echo "  $repo: clone failed (non-fatal)"
    fi
  done
  echo "c3-entrypoint: repos ready."

  # Generate cloud-topology.json + cloud-configs.json from cloned sources
  echo "c3-entrypoint: generating topology + configs..."
  npx tsx src/engines/gen-topology.ts || echo "  WARN: gen-topology failed"
  npx tsx src/engines/gen-configs.ts || echo "  WARN: gen-configs failed"
else
  echo "c3-entrypoint: no SSH key — skipping repo sync"
fi

exec npx tsx src/api/index.ts
