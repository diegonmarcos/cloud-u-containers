#!/bin/bash
#
# Palantir Monitor - Deployment Script
# Deploys to oci-f-micro_1 (Mail Server) at 130.110.251.193
#

set -e

echo "=========================================="
echo "Palantir Monitor - Deployment"
echo "=========================================="
echo ""

# Configuration
TARGET_VM="oci-f-micro_1"
TARGET_IP="130.110.251.193"
TARGET_USER="ubuntu"
SSH_KEY="~/vault/A0_keys/ssh/id_rsa"
DEPLOY_PATH="/opt/palantir-monitor"
LOCAL_PATH="$(cd "$(dirname "$0")" && pwd)"

echo "Target: $TARGET_USER@$TARGET_IP"
echo "Deploy Path: $DEPLOY_PATH"
echo "Local Path: $LOCAL_PATH"
echo ""

# Check if .env exists
if [[ ! -f "$LOCAL_PATH/.env" ]]; then
    echo "[ERROR] .env file not found!"
    echo "Please create .env with SMTP_PASS before deploying"
    exit 1
fi

echo "[1/5] Creating deployment directory on VM..."
ssh -i "$SSH_KEY" "$TARGET_USER@$TARGET_IP" "sudo mkdir -p $DEPLOY_PATH && sudo chown $TARGET_USER:$TARGET_USER $DEPLOY_PATH"

echo "[2/5] Copying files to VM..."
rsync -avz -e "ssh -i $SSH_KEY" \
    --exclude '.git' \
    --exclude '*.log' \
    --exclude 'reports/' \
    "$LOCAL_PATH/" "$TARGET_USER@$TARGET_IP:$DEPLOY_PATH/"

echo "[3/5] Setting permissions..."
ssh -i "$SSH_KEY" "$TARGET_USER@$TARGET_IP" "cd $DEPLOY_PATH && chmod +x scripts/*.sh entrypoint.sh"

echo "[4/5] Checking Docker..."
ssh -i "$SSH_KEY" "$TARGET_USER@$TARGET_IP" "docker --version"

echo "[5/5] Building and starting containers..."
ssh -i "$SSH_KEY" "$TARGET_USER@$TARGET_IP" << 'REMOTE_SCRIPT'
cd /opt/palantir-monitor

# Stop any existing containers
docker-compose down 2>/dev/null || true

# Build the image
docker-compose build

# Start the cron scheduler
docker-compose up -d palantir-cron

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "Status:"
docker-compose ps

echo ""
echo "Cron schedule: Daily at 7:00 AM UTC"
echo ""
echo "To run a manual test:"
echo "  ssh -i ~/vault/A0_keys/ssh/id_rsa ubuntu@130.110.251.193"
echo "  cd /opt/palantir-monitor"
echo "  docker-compose run --rm palantir-monitor"
echo ""
echo "To view logs:"
echo "  docker logs palantir-cron"
echo ""
echo "To view reports:"
echo "  docker volume ls | grep palantir"
echo "  docker run --rm -v palantir-monitor_palantir-reports:/reports alpine ls -lah /reports"
REMOTE_SCRIPT

echo ""
echo "✅ Palantir Monitor deployed successfully!"
echo ""
echo "Next: Wait for tomorrow's 7 AM UTC run, or run a manual test now"
