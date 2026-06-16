#!/bin/sh
# Runtime init for mail-puller. Launches the Rust binary with:
#   RUST_LOG       — log level (env or default info)
#   SOURCES_FILE   — path to declarative sources.json
#   STATE_DB       — sqlite DB of last-seen UIDs per source mailbox
#   SECRETS injected at container start via env_file (.secrets).
set -eu

export SOURCES_FILE="${SOURCES_FILE:-/etc/mail-puller/sources.json}"
export STATE_DB="${STATE_DB:-/var/lib/mail-puller/state.db}"
export RUST_LOG="${RUST_LOG:-mail_puller=info,async_imap=warn}"

mkdir -p "$(dirname "$STATE_DB")"

echo "[mail-puller] starting with sources=$SOURCES_FILE state=$STATE_DB log=$RUST_LOG"
exec /usr/local/bin/mail-puller
