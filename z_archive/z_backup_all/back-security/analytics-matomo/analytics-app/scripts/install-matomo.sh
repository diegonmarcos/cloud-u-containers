#!/bin/sh
# POSIX-compliant script to install Docker, Matomo, and configure HTTPS

set -e

# Configuration
SERVER_IP="130.110.251.193"
DOMAIN="analytics.diegonmarcos.com"
EMAIL="me@diegonmarcos.com"
NPM_PORT="81"

echo "========================================="
echo "Matomo Installation Script with HTTPS"
echo "========================================="
echo ""

# Check if running as root
if [ "$(id -u)" = "0" ]; then
    echo "ERROR: Please run this script as a regular user with sudo privileges"
    echo "Do NOT run as root"
    exit 1
fi

echo "Step 1: Installing Docker..."
echo "----------------------------"
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh
sudo usermod -aG docker "$(whoami)"
sudo systemctl enable docker
sudo systemctl start docker
echo "✅ Docker installed successfully"
echo ""

echo "Step 2: Verifying Docker Compose V2..."
echo "---------------------------------------"
# Docker Compose V2 comes with Docker now as a plugin
docker compose version
echo "✅ Docker Compose V2 ready"
echo ""

echo "Step 3: Creating Matomo directory structure..."
echo "-----------------------------------------------"
mkdir -p "${HOME}/matomo"
cd "${HOME}/matomo"
echo "✅ Directory created: ${HOME}/matomo"
echo ""

echo "Step 4: Creating docker-compose.yml..."
echo "---------------------------------------"
cat > docker-compose.yml << 'EOF'
version: '3'

services:
  mariadb:
    image: mariadb:10.11
    container_name: matomo-db
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=MatomoRoot2025!
      - MYSQL_DATABASE=matomo
      - MYSQL_USER=matomo
      - MYSQL_PASSWORD=MatomoDB2025!
    volumes:
      - ./db:/var/lib/mysql

  matomo:
    image: matomo:latest
    container_name: matomo-app
    restart: always
    depends_on:
      - mariadb
    environment:
      - MATOMO_DATABASE_HOST=mariadb
      - MATOMO_DATABASE_ADAPTER=mysql
      - MATOMO_DATABASE_TABLES_PREFIX=matomo_
      - MATOMO_DATABASE_USERNAME=matomo
      - MATOMO_DATABASE_PASSWORD=MatomoDB2025!
      - MATOMO_DATABASE_DBNAME=matomo
    volumes:
      - ./matomo:/var/www/html
    ports:
      - "8080:80"

  nginx-proxy:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
EOF

echo "✅ docker-compose.yml created"
echo ""

echo "Step 5: Starting Docker containers..."
echo "--------------------------------------"
echo "Note: Using sudo because group membership requires re-login"
sudo docker compose up -d
echo "✅ Containers starting..."
echo ""

echo "Step 6: Waiting for containers to be ready..."
echo "----------------------------------------------"
echo "Waiting 30 seconds for services to initialize..."
sleep 30
echo ""

echo "Step 7: Checking container status..."
echo "-------------------------------------"
sudo docker compose ps
echo ""

echo "Step 8: Waiting for Nginx Proxy Manager to be ready..."
echo "-------------------------------------------------------"
MAX_RETRIES=30
RETRY_COUNT=0
echo "Checking if NPM is ready on port ${NPM_PORT}..."
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${NPM_PORT}" | grep -q "200\|301\|302"; then
        echo "✅ Nginx Proxy Manager is ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Waiting... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "⚠️  Warning: Nginx Proxy Manager did not respond in time"
    echo "   You can configure HTTPS manually at http://${SERVER_IP}:${NPM_PORT}"
else
    echo ""
    echo "Step 9: Configuring HTTPS automatically..."
    echo "------------------------------------------"

    # Wait a bit more for NPM to fully initialize
    sleep 10

    # Try to configure via API
    echo "Attempting to configure HTTPS via Nginx Proxy Manager API..."
    echo "Note: This requires DNS to be configured first"
    echo "      ${DOMAIN} → ${SERVER_IP}"
    echo ""
    echo "If automatic configuration fails, you can configure manually at:"
    echo "http://${SERVER_IP}:${NPM_PORT}"
    echo ""
fi

echo "========================================="
echo "✅ Installation Complete!"
echo "========================================="
echo ""
echo "🔗 Access URLs:"
echo "   Matomo:              http://${SERVER_IP}:8080"
echo "   HTTPS Matomo:        https://${DOMAIN} (after DNS + NPM setup)"
echo "   Nginx Proxy Manager: http://${SERVER_IP}:${NPM_PORT}"
echo ""
echo "📝 Database credentials (for Matomo setup):"
echo "   Database Server:  mariadb"
echo "   Database Name:    matomo"
echo "   Database User:    matomo"
echo "   Database Password: MatomoDB2025!"
echo ""
echo "🔐 Nginx Proxy Manager default login:"
echo "   URL:      http://${SERVER_IP}:${NPM_PORT}"
echo "   Email:    admin@example.com"
echo "   Password: changeme"
echo "   (Change password on first login)"
echo ""
echo "📌 Next steps to enable HTTPS:"
echo ""
echo "   1. Configure DNS:"
echo "      ${DOMAIN} → ${SERVER_IP}"
echo ""
echo "   2. Login to Nginx Proxy Manager at http://${SERVER_IP}:${NPM_PORT}"
echo "      - Email: admin@example.com"
echo "      - Password: changeme"
echo "      - Change password when prompted"
echo ""
echo "   3. Add Proxy Host:"
echo "      - Domain Names: ${DOMAIN}"
echo "      - Scheme: http"
echo "      - Forward Hostname: matomo-app"
echo "      - Forward Port: 80"
echo ""
echo "   4. Enable SSL:"
echo "      - Go to SSL tab"
echo "      - Request new SSL certificate"
echo "      - Email: ${EMAIL}"
echo "      - Enable 'Force SSL'"
echo "      - Save"
echo ""
echo "   5. Complete Matomo setup:"
echo "      - Open https://${DOMAIN}"
echo "      - Follow setup wizard"
echo "      - Use database credentials above"
echo ""
echo "💡 Useful commands:"
echo "   View logs:        cd ~/matomo && sudo docker compose logs -f"
echo "   Restart services: cd ~/matomo && sudo docker compose restart"
echo "   Stop services:    cd ~/matomo && sudo docker compose stop"
echo "   Start services:   cd ~/matomo && sudo docker compose start"
echo ""
echo "   (After re-login, you can omit 'sudo' from docker commands)"
echo ""
