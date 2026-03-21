#!/bin/sh
# C3-API entrypoint: fix SSH keys, start server
# Topology is bind-mounted from host (cloud-data-topology.json) — no repo cloning needed.
set -e

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

echo "c3-entrypoint: topology at ${CONFIG_JSON_PATH:-/app/cloud-data-topology.json}"

exec npx tsx src/api/index.ts
