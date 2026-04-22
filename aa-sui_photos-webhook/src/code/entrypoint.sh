#!/bin/sh
# photos-webhook container entrypoint.
# Installs Python deps into /app/.deps (matches native_build.cmd +
# PYTHONPATH=/app/.deps), then execs the Flask webhook.
set -eu

if [ ! -d /app/.deps ] || [ -z "$(ls -A /app/.deps 2>/dev/null)" ]; then
    pip install --no-cache-dir --target=/app/.deps -r /app/requirements.txt
fi

exec python /app/webhook.py flask
