#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/src"
DIST="$DIR/dist"

mkdir -p "$DIST"

# Copy source files to dist
cp "$SRC/style.css"      "$DIST/style.css"
cp "$SRC/script.js"      "$DIST/script.js"

# Replace placeholders with <link>/<script> tags
sed \
  -e 's|<style>/\* __CSS__ \*/</style>|<link rel="stylesheet" href="style.css">|' \
  -e 's|<script>/\* __JS__ \*/</script>|<script src="script.js"></script>|' \
  "$SRC/dashboard.html" > "$DIST/index.html"

echo "Built → dist/ (index.html + style.css + script.js)"
