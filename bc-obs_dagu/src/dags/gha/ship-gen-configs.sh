#!/usr/bin/env bash
# ── Generate cloud-data configs from build.json + topology ──
# Usage: cloud-ship-orchestrate-gen-configs.sh
set -euo pipefail

REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"
export GIT_BASE="${GIT_BASE:-$(dirname "$REPO_ROOT")}"

echo "── Generating cloud-data ──"
bash build.sh config

echo "── Committing cloud-data ──"
cd cloud-data
git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"

git stash --include-untracked 2>/dev/null || true
git checkout main 2>/dev/null || true
git pull --rebase origin main 2>/dev/null || true
git stash pop 2>/dev/null || true

git add -A *.json *.md 2>/dev/null || true
if git diff --cached --quiet; then
  echo "cloud-data: no changes"
  exit 0
fi

git commit -m "auto: regenerate cloud-data [skip ci]"
git push origin main

echo "── Updating submodule ref ──"
cd "$REPO_ROOT"
git config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"
git checkout -- . 2>/dev/null || true
git add cloud-data
if git diff --cached --quiet; then
  echo "main repo: submodule ref unchanged"
  exit 0
fi
git commit -m "auto: update cloud-data submodule ref [skip ci]"
git push origin main
