#!/bin/sh
# Matomo Server Setup Script (POSIX-compliant)
# Sets up Docker and Matomo on Oracle Cloud Ubuntu server

set -e

# Configuration
SERVER_IP="130.110.251.193"
SSH_KEY="${HOME}/.ssh/matomo_key"
SSH_USER="ubuntu"
MATOMO_DB_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"
MATOMO_ROOT_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"

echo "========================================="
echo "Matomo Server Setup"
echo "========================================="
echo "Server: ${SERVER_IP}"
echo "User: ${SSH_USER}"
echo ""

# Check if SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo "ERROR: SSH key not found at ${SSH_KEY}"
    exit 1
fi

echo "Step 1: Connecting to server and installing Docker..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" << 'ENDSSH'
set -e

echo "Updating system packages..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

echo "Installing Docker..."
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sudo sh /tmp/get-docker.sh > /dev/null 2>&1
sudo usermod -aG docker ubuntu

echo "Installing Docker Compose..."
sudo apt-get install -y docker-compose

echo "Verifying Docker installation..."
docker --version
docker-compose --version

echo "Docker installation complete!"
ENDSSH

echo ""
echo "Step 2: Creating Matomo Docker configuration..."

# Create docker-compose file on remote server
ssh -i "${SSH_KEY}" "${SSH_USER}@${SERVER_IP}" "mkdir -p ~/matomo && cat > ~/matomo/docker-compose.yml" << EOF
version: '3'

services:
  mariadb:
    image: mariadb:10.11
    container_name: matomo-db
    environment:
      - MYSQL_ROOT_PASSWORD=${MATOMO_ROOT_PASSWORD}
      - MYSQL_DATABASE=matomo
      - MYSQL_USER=matomo
      - MYSQL_PASSWORD=${MATOMO_DB_PASSWORD}
    volumes:
      - ./mariadb:/var/lib/mysql
    restart: unless-stopped
    networks:
      - matomo-network

  matomo:
    image: matomo:latest
    container_name: matomo-app
    ports:
      - "8080:80"
    environment:
      - MATOMO_DATABASE_HOST=mariadb
      - MATOMO_DATABASE_ADAPTER=mysql
      - MATOMO_DATABASE_TABLES_PREFIX=matomo_
      - MATOMO_DATABASE_USERNAME=matomo
      - MATOMO_DATABASE_PASSWORD=${MATOMO_DB_PASSWORD}
      - MATOMO_DATABASE_DBNAME=matomo
    volumes:
      - ./matomo:/var/www/html
    depends_on:
      - mariadb
    restart: unless-stopped
    networks:
      - matomo-network

  nginx-proxy:
    image: nginxproxymanager/nginx-proxy-manager:latest
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    environment:
      - DB_SQLITE_FILE=/data/database.sqlite
    volumes:
      - ./nginx-proxy/data:/data
      - ./nginx-proxy/letsencrypt:/etc/letsencrypt
    restart: unless-stopped
    networks:
      - matomo-network

networks:
  matomo-network:
    driver: bridge
EOF

echo ""
echo "Step 3: Starting Matomo stack..."
ssh -i "${SSH_KEY}" "${SSH_USER}@${SERVER_IP}" << 'ENDSSH'
set -e
cd ~/matomo
echo "Pulling Docker images..."
docker-compose pull
echo "Starting containers..."
docker-compose up -d
echo "Waiting for services to start..."
sleep 10
docker-compose ps
ENDSSH

echo ""
echo "========================================="
echo "✅ Matomo Setup Complete!"
echo "========================================="
echo ""
echo "📊 Access URLs:"
echo "  • Matomo (HTTP): http://${SERVER_IP}:8080"
echo "  • Nginx Proxy Manager: http://${SERVER_IP}:81"
echo ""
echo "🔐 Nginx Proxy Manager Default Login:"
echo "  Email: admin@example.com"
echo "  Password: changeme"
echo "  ⚠️  CHANGE THIS IMMEDIATELY!"
echo ""
echo "🗄️  Database Credentials:"
echo "  Database: matomo"
echo "  User: matomo"
echo "  Password: ${MATOMO_DB_PASSWORD}"
echo "  Root Password: ${MATOMO_ROOT_PASSWORD}"
echo ""
echo "📝 Next Steps:"
echo "  1. Configure DNS: analytics.diegonmarcos.com → ${SERVER_IP}"
echo "  2. Setup Nginx Proxy Manager (port 81)"
echo "  3. Add SSL certificate for analytics.diegonmarcos.com"
echo "  4. Complete Matomo installation at https://analytics.diegonmarcos.com"
echo ""
echo "💾 Save these credentials securely!"
echo "========================================="

# Save credentials to file
cat > matomo-credentials.txt << CREDS
Matomo Server Credentials
=========================
Server IP: ${SERVER_IP}
SSH User: ${SSH_USER}
SSH Key: ${SSH_KEY}

Database Credentials:
Database: matomo
User: matomo
Password: ${MATOMO_DB_PASSWORD}
Root Password: ${MATOMO_ROOT_PASSWORD}

Nginx Proxy Manager:
URL: http://${SERVER_IP}:81
Default Email: admin@example.com
Default Password: changeme

Created: $(date)
CREDS

echo "Credentials saved to: matomo-credentials.txt"
