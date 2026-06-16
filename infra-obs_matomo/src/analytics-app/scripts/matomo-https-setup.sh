#!/bin/sh
# Matomo HTTPS Setup Script (POSIX-compliant)
# Configures Nginx Proxy Manager with Let's Encrypt SSL for analytics.diegonmarcos.com

set -e

SERVER_IP="130.110.251.193"
SSH_KEY="${HOME}/.ssh/matomo_key"
SSH_USER="ubuntu"
DOMAIN="analytics.diegonmarcos.com"

echo "========================================="
echo "Matomo HTTPS Setup"
echo "========================================="
echo "Domain: ${DOMAIN}"
echo "Server: ${SERVER_IP}"
echo ""

# Check if SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo "ERROR: SSH key not found at ${SSH_KEY}"
    exit 1
fi

# Check DNS
echo "Step 1: Verifying DNS configuration..."
DNS_IP=$(dig +short ${DOMAIN} | tail -1)
if [ "${DNS_IP}" = "${SERVER_IP}" ]; then
    echo "✅ DNS correctly points to ${SERVER_IP}"
else
    echo "⚠️  WARNING: DNS points to ${DNS_IP} but server is at ${SERVER_IP}"
    echo "Please configure DNS A record: ${DOMAIN} → ${SERVER_IP}"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [ "$REPLY" != "y" ]; then
        exit 1
    fi
fi

echo ""
echo "Step 2: Checking if Matomo is running..."
ssh -i "${SSH_KEY}" "${SSH_USER}@${SERVER_IP}" << 'ENDSSH'
set -e
cd ~/matomo
if docker-compose ps | grep -q "Up"; then
    echo "✅ Matomo containers are running"
else
    echo "Starting Matomo containers..."
    # Policy: VMs never build — pre-built images on GHCR.
    docker compose pull --quiet && docker compose up -d --no-build
    sleep 10
fi
ENDSSH

echo ""
echo "Step 3: Configuring Nginx Proxy Manager..."
echo ""
echo "📋 Manual Steps Required:"
echo ""
echo "1. Open Nginx Proxy Manager admin panel:"
echo "   🌐 http://${SERVER_IP}:81"
echo ""
echo "2. Login with default credentials:"
echo "   📧 Email: admin@example.com"
echo "   🔑 Password: changeme"
echo ""
echo "3. ⚠️  CHANGE PASSWORD IMMEDIATELY on first login!"
echo ""
echo "4. Add Proxy Host:"
echo "   • Click 'Proxy Hosts' → 'Add Proxy Host'"
echo "   • Details tab:"
echo "     - Domain Names: ${DOMAIN}"
echo "     - Scheme: http"
echo "     - Forward Hostname/IP: matomo-app"
echo "     - Forward Port: 80"
echo "     - ✓ Cache Assets"
echo "     - ✓ Block Common Exploits"
echo "     - ✓ Websockets Support"
echo ""
echo "5. SSL Certificate:"
echo "   • Click 'SSL' tab"
echo "   • SSL Certificate: Request a new SSL Certificate"
echo "   • ✓ Force SSL"
echo "   • ✓ HTTP/2 Support"
echo "   • ✓ HSTS Enabled"
echo "   • Email: me@diegonmarcos.com"
echo "   • ✓ I Agree to the Let's Encrypt Terms of Service"
echo "   • Click 'Save'"
echo ""
echo "6. Wait ~30 seconds for Let's Encrypt to issue certificate"
echo ""
echo "========================================="
echo ""

# Test HTTPS after manual setup
echo "After completing the above steps, test with:"
echo "  curl -I https://${DOMAIN}"
echo ""
echo "Or visit in browser:"
echo "  https://${DOMAIN}"
echo ""
echo "========================================="
echo ""
echo "📝 Next: Complete Matomo Installation"
echo "  1. Visit: https://${DOMAIN}"
echo "  2. Follow installation wizard"
echo "  3. Database credentials in: matomo-credentials.txt"
echo ""
