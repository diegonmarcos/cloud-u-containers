#!/bin/bash
# Decrypt secrets and start code-server
# Requires: sops, age key at ~/.config/sops/age/keys.txt

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check for sops
if ! command -v sops &> /dev/null; then
    echo "Error: sops not installed. Install with: nix-env -iA nixpkgs.sops"
    exit 1
fi

# Check for age key
AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [[ ! -f "$AGE_KEY" ]]; then
    echo "Error: Age key not found at $AGE_KEY"
    echo "Copy from vault: cp /path/to/vault/A0_keys/age/keys.txt ~/.config/sops/age/keys.txt"
    exit 1
fi

# Decrypt secrets to .env
echo "Decrypting secrets..."
export SOPS_AGE_KEY_FILE="$AGE_KEY"

SUDO_PASSWORD=$(sops -d --extract '["sudo_password"]' secrets.yaml)

# Detect if running on oci-p-flex_1 (has WireGuard IP 10.0.0.2)
BIND_IP="0.0.0.0"
if ip addr | grep -q "10.0.0.2"; then
    BIND_IP="10.0.0.2"
    echo "Detected oci-p-flex_1, binding to WireGuard IP: $BIND_IP"
fi

# Create .env file
cat > .env << EOF
SUDO_PASSWORD=$SUDO_PASSWORD
TZ=Europe/Madrid
BIND_IP=$BIND_IP
EOF

echo "Secrets decrypted to .env"

# Start docker compose
echo "Starting code-server..."
docker compose up -d

echo "Code-server running at http://localhost:8443"
