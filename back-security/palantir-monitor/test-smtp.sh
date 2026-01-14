#!/bin/bash
#
# Quick SMTP Test for Palantir Monitor
# Tests if the SMTP credentials work
#

# Load credentials
source .env

echo "=========================================="
echo "Testing SMTP Connection"
echo "=========================================="
echo "Server: smtp.diegonmarcos.com:465"
echo "User: no-reply@diegonmarcos.com"
echo "Password: ${SMTP_PASS:0:3}***"
echo ""

# Test SMTP connection with curl
echo "Attempting to connect to SMTPS (port 465)..."
echo ""

# Simple test email
TEMP_EMAIL="./test-email-temp.txt"
TEMP_LOG="./smtp-test-temp.log"

cat > "$TEMP_EMAIL" << EOF
From: no-reply@diegonmarcos.com
To: me@diegonmarcos.com
Subject: Palantir Monitor SMTP Test - $(date)

This is a test email from palantir-monitor setup.

If you receive this, the SMTP credentials are working correctly!

Timestamp: $(date)
Host: $(hostname)
EOF

# Try sending via curl SMTPS
if curl --url 'smtps://smtp.diegonmarcos.com:465' \
     --ssl-reqd \
     --mail-from 'no-reply@diegonmarcos.com' \
     --mail-rcpt 'me@diegonmarcos.com' \
     --user "no-reply@diegonmarcos.com:${SMTP_PASS}" \
     --upload-file "$TEMP_EMAIL" \
     --verbose 2>&1 | tee "$TEMP_LOG"; then
    echo ""
    echo "[OK] SMTP connection successful!"
    echo "Check me@diegonmarcos.com for test email"
else
    echo ""
    echo "[FAIL] SMTP connection failed"
    echo "Check $TEMP_LOG for details"
    exit 1
fi

rm -f "$TEMP_EMAIL" "$TEMP_LOG"
