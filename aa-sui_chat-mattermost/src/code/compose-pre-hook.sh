#!/bin/sh
# compose-pre-hook.sh — runs every pre_hook step in order before docker
# compose up. build.json#compose.pre_hook takes a single script path; this
# wrapper chains the individual concerns so each stays small and testable.
#
# Order:
#   1. fetch-mcp-bearer.sh — refresh BEARER_TOKEN via Authelia client-creds
#      (always, no marker — token lifetimes are short relative to deploys).
#   2. migrate-from-mattermost-bots.sh — one-time volume migration from the
#      old mattermost-bots project's prefix. Marker-gated, no-op after first
#      successful run.
#
# Soft-fail: each step is a `|| true` so an upstream blip never blocks the
# deploy. Failures show in pre_hook log lines only.
set -eu
DIR="$(dirname "$0")"

"$DIR/fetch-mcp-bearer.sh"            || echo "[pre-hook] fetch-mcp-bearer.sh failed (non-fatal)"
"$DIR/migrate-from-mattermost-bots.sh" || echo "[pre-hook] migrate-from-mattermost-bots.sh failed (non-fatal)"

exit 0
