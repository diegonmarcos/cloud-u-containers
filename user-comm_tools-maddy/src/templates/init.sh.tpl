#!/bin/sh
set -e

# Install jq + sqlite3 — required by:
#   /usr/local/bin/mail-sieve-subset-delivery-time (jq for per-message rule eval)
#   /usr/local/bin/mail-sieve-subset-post-hoc      (jq + sqlite3 for batch ops)
# Idempotent — no-op if already present (alpine apk).
for pkg in jq sqlite; do
  if ! command -v "${pkg%sqlite}sqlite3" >/dev/null 2>&1 && ! command -v "$pkg" >/dev/null 2>&1; then
    echo "[init] Installing $pkg..."
    apk add --no-cache "$pkg" >/dev/null 2>&1 || true
  fi
done

echo "[init] Generating maddy.conf from template..."
# maddy.conf uses native `{env:VAR}` interpolation for secrets — no sed,
# no shell-text mangling. Maddy reads env vars at config-load time.
# Source of every secret value: src/secrets.yaml -> env_file (.secrets) -> $env.
cp /etc/maddy/maddy.conf.tpl /data/maddy.conf

# Write DKIM private key from base64
if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
  echo "[init] Writing DKIM key..."
  mkdir -p /data/dkim
  echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > /data/dkim/@BASE_DOMAIN@.key
  chmod 600 /data/dkim/@BASE_DOMAIN@.key
fi

# Create accounts AND sync passwords on every boot.
# `creds create` errors if the account exists, so an existing account would
# keep a stale password forever (drift between secrets.yaml and the maddy
# credentials.db). Pair with `creds password` to UPSERT the secret —
# `creds create` for first-boot, `creds password` for password rotation.
# Pipe passwords via stdin — never `--password $VAR` (the value would land in
# process args / `docker top` / `ps` output). maddy's own --help carries the
# same warning. Source of every value is sops-encrypted src/secrets.yaml,
# which docker compose injects as env_file -> $ME_PASSWORD / $NOREPLY_PASSWORD.
#
# `printf '%s'` (no trailing \n) — `echo` would append a newline that maddy
# then bcrypts into the stored hash, so SMTP clients sending the bare value
# would never authenticate.
#
# Stderr stays visible so that any `creds password` failure (locked db,
# missing config block, version skew) shows up in `docker logs maddy`.
# `creds create` is expected to error on existing accounts — that's fine,
# `creds password` is the unconditional upsert.
echo "[init] Ensuring accounts + syncing passwords..."
# USER_CREATION_BLOCK below — generated from build.json#users at flake build time.
# Each entry produces: creds create + creds password + imap-acct create.
# Source: aa-sui_tools-maddy/build.json#users (this service's own SoT).
@USER_CREATION_BLOCK@

# FOLDER_CREATION_BLOCK below — the F0 sender-classification folders
# (mail-rules-general.json#filters.views, axis="sender"). Must exist before
# apply-rules' first COPY into them: its SQL only UPDATEs an existing mboxes
# row, never INSERTs one, so a missing folder makes every copy into it a
# silent no-op. `imap-mboxes create` errors on an existing folder — expected,
# same idempotent-boot pattern as USER_CREATION_BLOCK above.
echo "[init] Ensuring F0 sender-classification folders..."
@FOLDER_CREATION_BLOCK@

echo "[init] Starting maddy-sorter in background..."
# Compiled into this same image (build.json#docker.native_build, src/crate)
# from maddy's OWN src/, same as jmap-sorter is for Stalwart -- NOT a
# separate sidecar container (Stalwart's docker.* slot was free since its
# main app image is pulled upstream as-is; Maddy's isn't, so this native_build
# both compiles maddy-sorter AND still gets maddy itself for free from
# base_image=foxcpp/maddy:0.9). Runs its own poll loop internally
# (STARTUP_DELAY/POLL_INTERVAL env vars, same shape as jmap-sorter) -- no
# external Dagu cron, no wrapper shell loop. Was previously an external
# Dagu DAG that ssh'd in every 2 min and caused a real livelock incident
# (see git history / this repo's mail-sieve-subset-post-hoc.sh comments on
# cmd_apply_rules, now dead code kept only for manual/testing use).
# This container runs with `init: true` (docker-compose.yml), so tini is
# the real PID1 and reaps this backgrounded process's tree regardless of
# the `exec maddy` below (exec only replaces THIS shell's own image, it
# doesn't touch already-backgrounded children).
/usr/local/bin/maddy-sorter &

echo "[init] Starting Maddy..."
exec maddy -config /data/maddy.conf run
