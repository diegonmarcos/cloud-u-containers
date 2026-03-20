#!/bin/sh
# C3-API entrypoint: clone public repos (read-only), generate topology, start server
set -e

REPOS_DIR="${GIT_BASE:-/app/repos}"

# Fix SSH key/config permissions — mount is :ro with VM user's UID,
# SSH requires files owned by running user. Copy to writable location.
if [ -d /root/.ssh ]; then
  SSH_DIR=/tmp/.ssh-fixed
  mkdir -p "$SSH_DIR"
  cp /root/.ssh/* "$SSH_DIR/" 2>/dev/null || true
  chown -R root:root "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  chmod 600 "$SSH_DIR"/* 2>/dev/null || true
  # Override HOME so SSH finds the fixed keys
  export HOME=/tmp/c3-home
  mkdir -p "$HOME"
  ln -sfn "$SSH_DIR" "$HOME/.ssh"
  echo "c3-entrypoint: SSH keys copied to $SSH_DIR (fixed permissions)"
fi

# Clone/pull repos — public HTTPS, no SSH key needed
# Map local dir name → GitHub repo name (when they differ)
repo_url() {
  case "$1" in
    front) echo "https://github.com/diegonmarcos/diegonmarcos.github.io.git" ;;
    *)     echo "https://github.com/diegonmarcos/$1.git" ;;
  esac
}

echo "c3-entrypoint: syncing repos to $REPOS_DIR..."
for repo in cloud unix front tools; do
  dir="$REPOS_DIR/$repo"
  if [ -d "$dir/.git" ]; then
    echo "  $repo: pulling..."
    git -C "$dir" fetch --all --quiet 2>/dev/null && \
      git -C "$dir" reset --hard origin/main --quiet 2>/dev/null || \
      echo "  $repo: fetch failed (non-fatal)"
  else
    echo "  $repo: cloning..."
    rm -rf "$dir"
    git clone --depth 1 --single-branch --branch main \
      "$(repo_url "$repo")" "$dir" 2>/dev/null || \
      echo "  $repo: clone failed (non-fatal)"
  fi
done
echo "c3-entrypoint: repos ready."

# cloud-data-topology.json + cloud-data-configs.json come from the cloned cloud repo.
# gen-topology/gen-configs are desktop tools — running them in-container
# overwrites the good files with incomplete output (missing SSH context).
echo "c3-entrypoint: using topology from cloned cloud repo"

# Generate cloud-data-deps.json + front-deps.json (scans package.json across repos)
echo "c3-entrypoint: generating deps..."
npx tsx src/engines/gen-deps.ts 2>&1 || echo "c3-entrypoint: gen-deps failed (non-fatal)"

exec npx tsx src/api/index.ts
