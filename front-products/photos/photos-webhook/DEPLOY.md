# Photos Project Phase 1 - Deployment Guide

> Status: Ready to deploy
> Created: 2025-12-06

---

## Quick Start (5 minutes)

### 1. Configure Environment

```bash
cd /home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-p-flex_1/2.app/photos-webhook

# Copy template and edit
cp .env.example .env

# Edit .env with your credentials
# - DB_PASSWORD: PostgreSQL password
# - S3_ACCESS_KEY: Oracle S3 access key
# - S3_SECRET_KEY: Oracle S3 secret key
nano .env
```

### 2. Start Services

```bash
# Build and start PostgreSQL + Webhook processor
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f photos-webhook
```

### 3. Verify Database

```bash
# Connect to PostgreSQL
docker-compose exec photos-db psql -U photos_user -d photos

# Check tables created
\dt

# Check if webhook is healthy
curl http://localhost:5001/health
```

### 4. Upload Photos to S3

```bash
# Extract Google Takeout to local directory
# Then sync to S3 with rclone:

rclone sync ~/google-takeout/Photos/ :s3:photos/ \
  --s3-access-key-id=YOUR_KEY \
  --s3-secret-access-key=YOUR_SECRET \
  --s3-endpoint=https://eu-marseille-1.oraclecloud.com \
  --s3-region=eu-marseille-1
```

---

## Detailed Steps

### Step 1: Prepare S3 Credentials

You need:
- Oracle S3 Access Key ID
- Oracle S3 Secret Access Key

**To get these:**
1. Log in to Oracle Cloud Console
2. Go to: Identity → Users → Your User
3. API Keys section → Add API Key
4. Choose "Customer Secret Keys"
5. Copy the Access Key ID and Secret Key

### Step 2: Create .env File

```bash
cat > .env << 'EOF'
DB_PASSWORD=your_secure_postgres_password
S3_ACCESS_KEY=ocid1...
S3_SECRET_KEY=your_secret_key_here
S3_REGION=eu-marseille-1
S3_BUCKET=photos
WEBHOOK_PORT=5001
EOF
```

### Step 3: Start Services

```bash
docker-compose up -d
```

Wait for services to be healthy:
```bash
# Check PostgreSQL
docker-compose ps photos-db

# Check Webhook processor
docker-compose ps photos-webhook

# Both should show "Up"
```

### Step 4: Download Google Takeout

Google Takeout will give you download links. Download and extract:

```bash
# Create directory for photos
mkdir -p ~/photos-temp

# Download and extract Google Takeout
# (You'll provide the links)
unzip -q ~/Downloads/takeout-*.zip -d ~/photos-temp/
```

### Step 5: Upload to S3

Install rclone if not already installed:

```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Configure S3 remote
rclone config

# Follow prompts:
# - Name: oracle-s3
# - Type: s3
# - Provider: Other S3 compatible
# - Endpoint: https://eu-marseille-1.oraclecloud.com
# - Access Key: [your key]
# - Secret Key: [your secret]
# - ACL: private
```

Then sync:

```bash
rclone sync ~/photos-temp/ oracle-s3:photos/ \
  --progress \
  --transfers=4 \
  --checkers=8
```

### Step 6: Monitor Processing

As photos upload, the webhook processor automatically:
1. Extracts EXIF data
2. Reverse geocodes location
3. Computes perceptual hash
4. Stores in PostgreSQL

Check progress:

```bash
# Watch webhook logs
docker-compose logs -f photos-webhook

# Count photos in database
docker-compose exec photos-db psql -U photos_user -d photos -c "SELECT COUNT(*) FROM photos;"

# Check recent uploads
docker-compose exec photos-db psql -U photos_user -d photos -c "SELECT filename, taken_date, camera_model FROM photos ORDER BY indexed_at DESC LIMIT 10;"
```

---

## Troubleshooting

### PostgreSQL won't start

```bash
# Check logs
docker-compose logs photos-db

# If permission error, reset volume
docker-compose down -v
docker-compose up -d
```

### Webhook processor failing

```bash
# Check logs
docker-compose logs photos-webhook

# Verify S3 credentials
# Verify database credentials in .env
# Check S3 bucket exists and is accessible
```

### Photos not being indexed

```bash
# Manually test webhook with a single photo
docker-compose exec photos-webhook \
  python webhook.py photos/2024-01-01_photo.jpg photos

# Check database for that photo
docker-compose exec photos-db psql -U photos_user -d photos \
  -c "SELECT * FROM photos WHERE filename LIKE '%photo.jpg%';"
```

### S3 upload is slow

```bash
# Increase rclone transfers and checkers
rclone sync ~/photos-temp/ oracle-s3:photos/ \
  --transfers=8 \
  --checkers=16 \
  --progress
```

---

## Next: Deploy PhotoView

Once photos are uploaded and indexed:

```bash
cd /home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-p-flex_1/2.app/photoview

# Create docker-compose for PhotoView
# Will use same PostgreSQL database
```

---

## File Structure

```
/home/diego/Documents/Git/back-System/cloud/vps_oracle/vm-oci-p-flex_1/2.app/
├── photos-webhook/
│   ├── schema.sql           # PostgreSQL schema
│   ├── webhook.py           # Webhook processor
│   ├── requirements.txt      # Python dependencies
│   ├── docker-compose.yml    # Services
│   ├── Dockerfile           # Webhook image
│   ├── .env                 # Credentials (DO NOT COMMIT)
│   ├── .env.example         # Template
│   └── DEPLOY.md            # This file
│
├── photoview/
│   └── docker-compose.yml    # PhotoView service (Phase 2)
│
├── photoprism/
│   └── docker-compose.yml    # Photoprism service (Phase 2)
│
└── immich/
    └── docker-compose.yml    # Immich service (Phase 2)
```

---

## Commands Reference

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# View logs
docker-compose logs -f

# Access PostgreSQL
docker-compose exec photos-db psql -U photos_user -d photos

# Restart a service
docker-compose restart photos-webhook

# Remove all data (WARNING: deletes database!)
docker-compose down -v
```

---

## Cost Tracking

- PostgreSQL: Free (local)
- Webhook processor: Free (local)
- S3 storage: $7.14/month (after 20GB free)
- PhotoView: Free (local)

---

**Ready?** Provide Google Takeout links to begin!
