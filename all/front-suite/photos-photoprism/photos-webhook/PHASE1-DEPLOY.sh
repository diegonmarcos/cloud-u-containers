#!/bin/bash
set -e

################################################################################
# Photos Project Phase 1 - Full Deployment Script
# Deploys: PostgreSQL + Webhook processor + google-takeout-downloader
# Usage: bash PHASE1-DEPLOY.sh
################################################################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

################################################################################
# STEP 1: Verify Prerequisites
################################################################################
log_info "Step 1: Verifying prerequisites..."

if ! command -v docker &> /dev/null; then
    log_error "Docker not installed. Please install Docker first."
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    log_error "Docker Compose not installed."
    exit 1
fi

log_success "Docker and Docker Compose found"

################################################################################
# STEP 2: Extract Oracle S3 Credentials
################################################################################
log_info "Step 2: Extracting Oracle S3 credentials..."

ORACLE_CONFIG="${HOME}/Documents/Git/LOCAL_KEYS/00_terminal/oracle/config"

if [ ! -f "$ORACLE_CONFIG" ]; then
    log_error "Oracle config not found at $ORACLE_CONFIG"
    exit 1
fi

# Parse OCI config for tenancy, user, key_file
TENANCY=$(grep "^tenancy=" "$ORACLE_CONFIG" | cut -d= -f2)
USER=$(grep "^user=" "$ORACLE_CONFIG" | cut -d= -f2)
FINGERPRINT=$(grep "^fingerprint=" "$ORACLE_CONFIG" | cut -d= -f2)

if [ -z "$TENANCY" ] || [ -z "$USER" ]; then
    log_error "Could not parse Oracle credentials from $ORACLE_CONFIG"
    exit 1
fi

log_success "Extracted Oracle credentials:"
log_info "  Tenancy: $TENANCY"
log_info "  User: $USER"
log_info "  Fingerprint: $FINGERPRINT"

################################################################################
# STEP 3: Create .env File with S3 Credentials
################################################################################
log_info "Step 3: Creating .env file..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    log_warn ".env already exists. Backing up to .env.backup"
    cp "$ENV_FILE" "$ENV_FILE.backup"
fi

# Generate secure PostgreSQL password
DB_PASSWORD=$(openssl rand -base64 32)

cat > "$ENV_FILE" << 'EOF'
# PostgreSQL Configuration
DB_PASSWORD=SECURE_PASSWORD_GENERATED

# S3 Configuration (Oracle)
S3_ACCESS_KEY=ocid1...
S3_SECRET_KEY=your_secret_key_here
S3_REGION=eu-marseille-1
S3_BUCKET=photos

# Webhook Configuration
WEBHOOK_PORT=5001

# Google Takeout
GOOGLE_EMAIL=your-email@gmail.com
GOOGLE_APP_PASSWORD=your_app_password_here

# Logging
LOG_LEVEL=INFO
EOF

# Update with actual password
sed -i "s/SECURE_PASSWORD_GENERATED/$DB_PASSWORD/" "$ENV_FILE"

log_success "Created .env file"
log_warn "Please edit $ENV_FILE and add:"
log_warn "  1. S3_ACCESS_KEY (from Oracle Cloud)"
log_warn "  2. S3_SECRET_KEY (from Oracle Cloud)"
log_warn "  3. GOOGLE_EMAIL (your Google account)"
log_warn "  4. GOOGLE_APP_PASSWORD (16-char password from Google)"

################################################################################
# STEP 4: Start PostgreSQL + Webhook Processor
################################################################################
log_info "Step 4: Starting Docker services (PostgreSQL + Webhook processor)..."

cd "$SCRIPT_DIR"

# Check if services already running
if docker-compose ps 2>/dev/null | grep -q "photos-db"; then
    log_warn "Services already running. Skipping docker-compose up."
else
    log_info "Building and starting services..."
    docker-compose up -d

    # Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    sleep 10

    # Test connection
    if docker-compose exec -T photos-db pg_isready -U photos_user -d photos &>/dev/null; then
        log_success "PostgreSQL is ready"
    else
        log_error "PostgreSQL failed to start. Check logs:"
        docker-compose logs photos-db
        exit 1
    fi
fi

log_success "Docker services running"
docker-compose ps

################################################################################
# STEP 5: Install google-takeout-downloader
################################################################################
log_info "Step 5: Installing google-takeout-downloader..."

if ! python3 -m pip show google-takeout-downloader &>/dev/null; then
    pip install google-takeout-downloader
    log_success "Installed google-takeout-downloader"
else
    log_warn "google-takeout-downloader already installed"
fi

################################################################################
# STEP 6: Create Download Directory
################################################################################
log_info "Step 6: Creating download directory..."

DOWNLOAD_DIR="/mnt/photos-temp"
sudo mkdir -p "$DOWNLOAD_DIR"
sudo chown $USER:$USER "$DOWNLOAD_DIR"

log_success "Download directory ready: $DOWNLOAD_DIR"

################################################################################
# STEP 7: Create Download Script
################################################################################
log_info "Step 7: Creating download script..."

DOWNLOAD_SCRIPT="$SCRIPT_DIR/download-and-upload.sh"

cat > "$DOWNLOAD_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
set -e

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Load environment
source .env

DOWNLOAD_DIR="/mnt/photos-temp"

################################################################################
# STEP 1: Download from Google Takeout
################################################################################
log_info "Downloading from Google Takeout..."
log_info "Email: $GOOGLE_EMAIL"
log_info "Output: $DOWNLOAD_DIR"

google-takeout-downloader \
  --email "$GOOGLE_EMAIL" \
  --password "$GOOGLE_APP_PASSWORD" \
  --output-dir "$DOWNLOAD_DIR" \
  --continue-incomplete

log_success "Download complete!"

################################################################################
# STEP 2: Unzip Takeout Files
################################################################################
log_info "Unzipping Takeout files..."

cd "$DOWNLOAD_DIR"
for zipfile in takeout-*.zip; do
    if [ -f "$zipfile" ]; then
        log_info "Unzipping: $zipfile"
        unzip -q "$zipfile" || log_info "Some files may already be extracted"
    fi
done

log_success "Takeout files ready in: $DOWNLOAD_DIR"

################################################################################
# STEP 3: Configure rclone for S3
################################################################################
log_info "Configuring rclone for Oracle S3..."

# Create rclone config
mkdir -p ~/.config/rclone

cat > ~/.config/rclone/rclone.conf << EOF_RCLONE
[oracle-s3]
type = s3
provider = Other
env_auth = false
access_key_id = $S3_ACCESS_KEY
secret_access_key = $S3_SECRET_KEY
endpoint = https://eu-marseille-1.oraclecloud.com
region = eu-marseille-1
storage_class = STANDARD
acl = private
EOF_RCLONE

chmod 600 ~/.config/rclone/rclone.conf
log_success "rclone configured"

################################################################################
# STEP 4: Upload to S3
################################################################################
log_info "Starting upload to S3..."
log_info "Source: $DOWNLOAD_DIR/Takeout/Google Photos"
log_info "Destination: s3://photos"

# Use multiple concurrent transfers for speed
rclone sync "$DOWNLOAD_DIR/Takeout/Google Photos" oracle-s3:photos/ \
  --progress \
  --transfers=8 \
  --checkers=16 \
  --stats=10s \
  --stats-log-level NOTICE

log_success "Upload complete!"

################################################################################
# STEP 5: Monitor Processing
################################################################################
log_info "Monitoring PostgreSQL indexing..."
log_info "Checking photo count every 10 seconds..."

while true; do
    COUNT=$(docker exec photos-db psql -U photos_user -d photos -t -c "SELECT COUNT(*) FROM photos;")
    SIZE=$(docker exec photos-db psql -U photos_user -d photos -t -c "SELECT ROUND(SUM(size_bytes)/1024/1024/1024.0, 2) FROM photos;")

    echo "Photos indexed: $COUNT | Total size: ${SIZE}GB"
    sleep 10
done

SCRIPT_EOF

chmod +x "$DOWNLOAD_SCRIPT"
log_success "Created download script: $DOWNLOAD_SCRIPT"

################################################################################
# STEP 8: Summary
################################################################################
log_success "=========================================="
log_success "Phase 1 Setup Complete!"
log_success "=========================================="

echo ""
echo -e "${BLUE}NEXT STEPS:${NC}"
echo ""
echo "1. Edit .env file with credentials:"
echo "   nano $ENV_FILE"
echo ""
echo "   Required:"
echo "   - S3_ACCESS_KEY (from Oracle Cloud)"
echo "   - S3_SECRET_KEY (from Oracle Cloud)"
echo "   - GOOGLE_EMAIL (your Google account)"
echo "   - GOOGLE_APP_PASSWORD (from https://myaccount.google.com/apppasswords)"
echo ""
echo "2. Start download and upload:"
echo "   bash $DOWNLOAD_SCRIPT"
echo ""
echo "3. Monitor services:"
echo "   docker-compose logs -f"
echo ""
echo "4. Check PostgreSQL:"
echo "   docker-compose exec photos-db psql -U photos_user -d photos"
echo ""
echo -e "${GREEN}Services running:${NC}"
docker-compose ps
echo ""
echo -e "${BLUE}PostgreSQL:${NC} localhost:5432"
echo -e "${BLUE}Webhook:${NC} localhost:5001"
echo -e "${BLUE}Health:${NC} curl http://localhost:5001/health"
