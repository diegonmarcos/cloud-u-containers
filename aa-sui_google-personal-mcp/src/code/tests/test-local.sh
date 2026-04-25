#!/usr/bin/env bash
# Local tester wrapper — decrypts secrets via sops, exports env, runs tester.
# Usage: src/code/tests/test-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # src/
CODE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"             # src/code/

if ! command -v sops >/dev/null 2>&1; then
  echo "ERROR: sops not in PATH" >&2; exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node not in PATH" >&2; exit 1
fi

SECRETS_YAML="$SRC_DIR/secrets.yaml"
if [ ! -f "$SECRETS_YAML" ]; then
  echo "ERROR: $SECRETS_YAML not found" >&2; exit 1
fi

# Decrypt to a temp env file (auto-cleaned)
ENV_TMP="$(mktemp --suffix=.env)"
trap 'rm -f "$ENV_TMP"' EXIT
sops --decrypt --output-type=dotenv "$SECRETS_YAML" > "$ENV_TMP"

# shellcheck disable=SC1090
set -a
. "$ENV_TMP"
set +a

cd "$CODE_DIR"
[ -d node_modules ] || npm install
exec npx tsx tests/run.ts "$@"
