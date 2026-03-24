#!/usr/bin/env bash
# Download octocode binary for the current platform
# Called by: npm postinstall
set -euo pipefail

VERSION="0.12.2"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin"
TARGET="$BIN_DIR/octocode"

if [ -x "$TARGET" ] && "$TARGET" --version 2>/dev/null | grep -q "$VERSION"; then
  echo "[octocode] v$VERSION already installed"
  exit 0
fi

ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

case "$OS-$ARCH" in
  linux-x86_64)   TRIPLE="x86_64-unknown-linux-musl" ;;
  linux-aarch64)   TRIPLE="aarch64-unknown-linux-musl" ;;
  darwin-x86_64)   TRIPLE="x86_64-apple-darwin" ;;
  darwin-arm64)    TRIPLE="aarch64-apple-darwin" ;;
  *)
    echo "[octocode] Unsupported platform: $OS-$ARCH — octocode tools will be unavailable"
    exit 0
    ;;
esac

URL="https://github.com/Muvon/octocode/releases/download/${VERSION}/octocode-${VERSION}-${TRIPLE}.tar.gz"
mkdir -p "$BIN_DIR"

echo "[octocode] Downloading v$VERSION for $TRIPLE..."
curl -sfL "$URL" | tar xz -C "$BIN_DIR" 2>/dev/null || {
  echo "[octocode] Download failed — octocode tools will be unavailable"
  exit 0
}

chmod +x "$TARGET"
echo "[octocode] Installed: $TARGET"
