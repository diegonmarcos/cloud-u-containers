#!/bin/sh
# C3-API entrypoint: clone public repos (read-only), generate topology, start server
set -e

REPOS_DIR="${GIT_BASE:-/app/repos}"


# Clone/pull repos — public HTTPS, no SSH key needed
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
      https://github.com/diegonmarcos/$repo.git "$dir" 2>/dev/null || \
      echo "  $repo: clone failed (non-fatal)"
  fi
done
echo "c3-entrypoint: repos ready."

# cloud-topology.json + cloud-configs.json come from the cloned cloud repo.
# gen-topology/gen-configs are desktop tools — running them in-container
# overwrites the good files with incomplete output (missing SSH context).
echo "c3-entrypoint: using topology from cloned cloud repo"

exec npx tsx src/api/index.ts
