#!/bin/sh
# Automated Nginx Proxy Manager Configuration via API
# Configures HTTPS proxy for analytics.diegonmarcos.com

set -e

SERVER_IP="130.110.251.193"
DOMAIN="analytics.diegonmarcos.com"
EMAIL="me@diegonmarcos.com"
NPM_PORT="81"

echo "========================================="
echo "Nginx Proxy Manager API Configuration"
echo "========================================="
echo ""

# Get credentials
echo "Enter Nginx Proxy Manager credentials:"
read -p "Email: " NPM_EMAIL
read -sp "Password: " NPM_PASSWORD
echo ""
echo ""

# Login and get token
echo "Logging in to Nginx Proxy Manager..."
TOKEN=$(curl -s -X POST "http://${SERVER_IP}:${NPM_PORT}/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${NPM_EMAIL}\",\"secret\":\"${NPM_PASSWORD}\"}" | \
  grep -o '"token":"[^"]*' | cut -d'"' -f4)

if [ -z "${TOKEN}" ]; then
    echo "❌ Failed to login. Check credentials."
    exit 1
fi

echo "✅ Login successful"
echo ""

# Create proxy host
echo "Creating proxy host for ${DOMAIN}..."
PROXY_RESPONSE=$(curl -s -X POST "http://${SERVER_IP}:${NPM_PORT}/api/nginx/proxy-hosts" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"domain_names\": [\"${DOMAIN}\"],
    \"forward_scheme\": \"http\",
    \"forward_host\": \"matomo-app\",
    \"forward_port\": 80,
    \"access_list_id\": 0,
    \"certificate_id\": 0,
    \"ssl_forced\": 0,
    \"caching_enabled\": 1,
    \"block_exploits\": 1,
    \"advanced_config\": \"\",
    \"meta\": {
      \"letsencrypt_agree\": true,
      \"dns_challenge\": false
    },
    \"allow_websocket_upgrade\": 1,
    \"http2_support\": 1,
    \"hsts_enabled\": 1,
    \"hsts_subdomains\": 0
  }")

PROXY_ID=$(echo "${PROXY_RESPONSE}" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ -z "${PROXY_ID}" ]; then
    echo "❌ Failed to create proxy host"
    echo "${PROXY_RESPONSE}"
    exit 1
fi

echo "✅ Proxy host created (ID: ${PROXY_ID})"
echo ""

# Request SSL certificate
echo "Requesting Let's Encrypt SSL certificate..."
SSL_RESPONSE=$(curl -s -X POST "http://${SERVER_IP}:${NPM_PORT}/api/nginx/certificates" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"provider\": \"letsencrypt\",
    \"domain_names\": [\"${DOMAIN}\"],
    \"meta\": {
      \"letsencrypt_email\": \"${EMAIL}\",
      \"letsencrypt_agree\": true,
      \"dns_challenge\": false
    }
  }")

CERT_ID=$(echo "${SSL_RESPONSE}" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ -z "${CERT_ID}" ]; then
    echo "❌ Failed to request SSL certificate"
    echo "${SSL_RESPONSE}"
    exit 1
fi

echo "✅ SSL certificate requested (ID: ${CERT_ID})"
echo "   Waiting for Let's Encrypt to issue certificate..."
sleep 30

# Update proxy host with SSL
echo "Enabling SSL on proxy host..."
curl -s -X PUT "http://${SERVER_IP}:${NPM_PORT}/api/nginx/proxy-hosts/${PROXY_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"domain_names\": [\"${DOMAIN}\"],
    \"forward_scheme\": \"http\",
    \"forward_host\": \"matomo-app\",
    \"forward_port\": 80,
    \"certificate_id\": ${CERT_ID},
    \"ssl_forced\": 1,
    \"caching_enabled\": 1,
    \"block_exploits\": 1,
    \"allow_websocket_upgrade\": 1,
    \"http2_support\": 1,
    \"hsts_enabled\": 1,
    \"hsts_subdomains\": 0
  }" > /dev/null

echo "✅ SSL enabled with force HTTPS redirect"
echo ""
echo "========================================="
echo "✅ HTTPS Setup Complete!"
echo "========================================="
echo ""
echo "🌐 Your Matomo is now available at:"
echo "   https://${DOMAIN}"
echo ""
echo "🔒 SSL Certificate:"
echo "   • Provider: Let's Encrypt"
echo "   • Auto-renewal: Enabled"
echo "   • HSTS: Enabled"
echo "   • HTTP/2: Enabled"
echo ""
echo "Test with:"
echo "  curl -I https://${DOMAIN}"
echo ""
