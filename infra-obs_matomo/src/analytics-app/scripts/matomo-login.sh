#!/bin/sh
# Matomo Server Login Script (POSIX-compliant)
# Quick SSH access to Matomo server

set -e

SERVER_IP="130.110.251.193"
SSH_KEY="${HOME}/.ssh/matomo_key"
SSH_USER="ubuntu"

# Check if SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo "ERROR: SSH key not found at ${SSH_KEY}"
    exit 1
fi

echo "Connecting to Matomo server..."
echo "Server: ${SERVER_IP}"
echo ""

ssh -i "${SSH_KEY}" "${SSH_USER}@${SERVER_IP}"
