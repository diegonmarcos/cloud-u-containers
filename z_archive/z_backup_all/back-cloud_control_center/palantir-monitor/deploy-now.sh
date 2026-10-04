#!/data/data/com.termux/files/usr/bin/bash
set -e

VM="130.110.251.193"
KEY="$HOME/vault/A0_keys/ssh/id_rsa"
DEST="/opt/palantir-monitor"

echo "=== Deploying Palantir Monitor ==="
echo ""

# Copy main files
echo "[1/6] Copying main files..."
scp -i "$KEY" Dockerfile docker-compose.yml entrypoint.sh .env .gitignore ubuntu@$VM:$DEST/

# Copy config directory
echo "[2/6] Copying config..."
ssh -i "$KEY" ubuntu@$VM "mkdir -p $DEST/config"
scp -i "$KEY" config/endpoints.conf ubuntu@$VM:$DEST/config/

# Copy scripts directory
echo "[3/6] Copying scripts..."
ssh -i "$KEY" ubuntu@$VM "mkdir -p $DEST/scripts"
scp -i "$KEY" scripts/*.sh ubuntu@$VM:$DEST/scripts/

# Set permissions
echo "[4/6] Setting permissions..."
ssh -i "$KEY" ubuntu@$VM "cd $DEST && chmod +x scripts/*.sh entrypoint.sh"

# Build and start
echo "[5/6] Building Docker image..."
ssh -i "$KEY" ubuntu@$VM "cd $DEST && docker-compose down 2>/dev/null || true && docker-compose build"

echo "[6/6] Starting palantir-cron..."
ssh -i "$KEY" ubuntu@$VM "cd $DEST && docker-compose up -d palantir-cron"

echo ""
echo "=== Deployment Complete ==="
echo ""
ssh -i "$KEY" ubuntu@$VM "cd $DEST && docker-compose ps"

echo ""
echo "=== Running Test ==="
echo ""
ssh -i "$KEY" ubuntu@$VM "cd $DEST && docker-compose run --rm palantir-monitor"

echo ""
echo "=== Test Complete ==="
