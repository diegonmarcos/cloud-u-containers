#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# Send the pre-built HTML report via EXTERNAL outbound submission.
#
# Mail MUST leave the cloud and re-enter through the public MX so it lands in
# EVERY copy of the recipient (Google Workspace + maddy + stalwart). maddy and
# stalwart both route a local-sender submission to their remote_queue → OCI
# relay (the paid egress; OCI/GCP free tier blocks direct :25/:465/:587 MX).
# NEVER deliver internally — an internal/loopback path only reaches the local
# maddy/stalwart mailbox and never the Google Workspace copy.
#
# Transport is maddy primary, stalwart fallback — both external. All values are
# data-driven from env (the Dagu DAG declares them); defaults below are the
# live oci-mail submission endpoints:
#   MAIL_FROM                  envelope + header From      (no-reply@diegonmarcos.com)
#   MAIL_TO                    recipient                   (me@diegonmarcos.com)
#   MAIL_USER                  SMTP-AUTH user              (no-reply@diegonmarcos.com)
#   MAIL_SUBMIT_PRIMARY        maddy    SMTPS submission   (smtps://10.0.0.3:465)
#   MAIL_SUBMIT_FALLBACK       stalwart SMTPS submission   (smtps://10.0.0.3:2465)
#   NOREPLY_PASSWORD           primary (maddy) AUTH secret           [required]
#   STALWART_NOREPLY_PASSWORD  fallback (stalwart) AUTH secret       [defaults to NOREPLY_PASSWORD]
#
# Usage: send.sh [html_file]   (defaults to the shared reports/dist/ HTML)
# ══════════════════════════════════════════════════════════════════════
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reports engine writes to the SHARED reports/dist/, not per-crate dist/.
# SCRIPT_DIR = reports/src/cloud-health-full-daily/src/  →  reports/ is 3 up.
HTML_FILE="${1:-$SCRIPT_DIR/../../../dist/cloud_health_daily.html}"
DATE=$(date '+%Y-%m-%d')

MAIL_FROM="${MAIL_FROM:-no-reply@diegonmarcos.com}"
MAIL_TO="${MAIL_TO:-me@diegonmarcos.com}"
MAIL_USER="${MAIL_USER:-no-reply@diegonmarcos.com}"
# R3: Mail submission endpoints MUST come from environment (derived from
# consolidated JSON in entrypoint.sh). No hardcoded IPs — oci-mail WG IP
# and ports are data in the topology, not constants in scripts.
# Dagu DAG declares these; entrypoint.sh derives them from consolidated JSON.
: "${MAIL_SUBMIT_PRIMARY:?MAIL_SUBMIT_PRIMARY required (smtps://<oci-mail-wg-ip>:465 from topology)}"
: "${MAIL_SUBMIT_FALLBACK:?MAIL_SUBMIT_FALLBACK required (smtps://<oci-mail-wg-ip>:2465 from topology)}"
: "${NOREPLY_PASSWORD:?NOREPLY_PASSWORD required for outbound SMTP-AUTH}"
STALWART_NOREPLY_PASSWORD="${STALWART_NOREPLY_PASSWORD:-$NOREPLY_PASSWORD}"

if [ ! -f "$HTML_FILE" ]; then
  echo "ERROR: HTML file not found: $HTML_FILE" >&2
  echo "Run the report engine first to generate it." >&2
  exit 1
fi

# Build MIME message (headers + base64-encoded HTML body). Maddy/RFC 5321 cap
# DATA lines at 998 octets; the minified HTML has very long lines, so base64
# with 76-col linewrap (`-w 76`) keeps every body line legal.
MIME_FILE=$(mktemp)
trap 'rm -f "$MIME_FILE"' EXIT

cat > "$MIME_FILE" <<EOHEADERS
From: $MAIL_FROM
To: $MAIL_TO
Subject: C3 Daily Ops Report - $DATE
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
Content-Transfer-Encoding: base64

EOHEADERS

base64 -w 76 < "$HTML_FILE" >> "$MIME_FILE"

# DIRECT LOCAL DUAL-DELIVERY into both mailboxes (Maddy=IMAP, Stalwart=JMAP).
#
# The external round-trip (submit as no-reply@diegonmarcos.com → maddy/stalwart
# remote_queue → OCI relay → public MX → back into the mailboxes) is unreliable:
# the OCI-relay → Cloudflare hop drops the mail on sender-auth (SPF/DKIM/DMARC),
# so the report never lands anywhere. Instead we do exactly what mail-puller
# does for pulled mail: authenticate as no-reply@ but present an EXTERNAL
# envelope MAIL FROM, so maddy/stalwart match `default_source` → local_routing
# (local mailbox delivery) instead of the outbound remote_queue. The display
# `From:` header stays no-reply@diegonmarcos.com. Requires no-reply@ to share
# one password across Maddy + Stalwart (aligned with LOCAL_DELIVERY_PASSWORD).
LOCAL_ENVELOPE_FROM="${LOCAL_ENVELOPE_FROM:-no-reply@bounce.diegonmarcos.com}"

deliver_local() {
  # $1 = submission URL (smtps://<oci-mail>:<port>)   $2 = SMTP-AUTH user   $3 = password
  curl -s --show-error --url "$1" --ssl-reqd -k \
    --user "$2:$3" \
    --mail-from "$LOCAL_ENVELOPE_FROM" \
    --mail-rcpt "$MAIL_TO" \
    -T "$MIME_FILE"
}

# Stalwart's no-reply@ password is set once at stalwart-cli bootstrap and never
# rotated at runtime (no principal-write API: JMAP Principal/set → 400, REST
# /api/principal → 404), so it drifts from the deployed secret and rejects
# no-reply@. Authenticate the Stalwart leg as the *recipient* principal (me@,
# STALWART_LOGIN_*) — the report is delivered to me@ anyway, and me@'s password
# IS managed — while Maddy keeps the no-reply@ submission that works there.
STALWART_LOGIN_USER="${STALWART_LOGIN_USER:-$MAIL_TO}"
STALWART_LOGIN_PASSWORD="${STALWART_LOGIN_PASSWORD:-$STALWART_NOREPLY_PASSWORD}"

RC=0
if deliver_local "$MAIL_SUBMIT_PRIMARY" "$MAIL_USER" "$NOREPLY_PASSWORD"; then
  echo "C3 Daily Ops Report $DATE → Maddy local mailbox (IMAP) via $MAIL_SUBMIT_PRIMARY"
else
  echo "FAILED local delivery to Maddy ($MAIL_SUBMIT_PRIMARY)" >&2; RC=1
fi
# Stalwart: the :2465 SUBMISSION port rejects a MAIL FROM that isn't the
# authenticated principal (501 — proven live: authenticating as me@ with an
# external LOCAL_ENVELOPE_FROM still returns 501). Deliver instead to Stalwart's
# inbound MX (:2025): it accepts local-domain RCPT (me@) UNauthenticated and
# stores it in me@'s mailbox. --ssl = opportunistic STARTTLS, -k tolerates the
# internal self-signed cert. Endpoint derived from MAIL_SUBMIT_FALLBACK
# (smtps://IP:2465 → smtp://IP:2025). Proven: a probe to :2025 lands in
# Stalwart's me@ JMAP mailbox.
_sl="${MAIL_SUBMIT_FALLBACK/smtps:\/\//smtp:\/\/}"
STALWART_LOCAL_MX="${STALWART_LOCAL_MX:-${_sl/:2465/:2025}}"
if curl -s --show-error --url "$STALWART_LOCAL_MX" --ssl -k \
     --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" -T "$MIME_FILE"; then
  echo "C3 Daily Ops Report $DATE → Stalwart local mailbox (JMAP) via $STALWART_LOCAL_MX (MX, RCPT $MAIL_TO)"
else
  echo "FAILED local delivery to Stalwart ($STALWART_LOCAL_MX)" >&2; RC=1
fi
exit $RC
