#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Matomo -> Umami data migration                                  ║
# ║                                                                  ║
# ║ Runs ON oci-apps host (invoked via lifecycle.migrate-from-matomo).║
# ║ Reads declarative config.json, extracts from matomo-hybrid via  ║
# ║ docker exec mysql, transforms to Umami schema, imports into     ║
# ║ umami-db via docker exec psql.                                  ║
# ║                                                                  ║
# ║ Idempotent: UUIDs are deterministically derived from matomo IDs ║
# ║ (md5 namespace) so reruns ON CONFLICT DO NOTHING into Umami.    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SELF_DIR/config.json"
[ -f "$CONFIG" ] || { echo "[migrate] FATAL: config.json not found at $CONFIG" >&2; exit 1; }

# ── Load declarative config (all values come from config.json) ────────
SOURCE_CONTAINER=$(jq -r '.source.container' "$CONFIG")
SOURCE_DB=$(jq -r '.source.db.database' "$CONFIG")
SOURCE_USER=$(jq -r '.source.db.user' "$CONFIG")
SOURCE_PASS_ENV=$(jq -r '.source.db.password_env' "$CONFIG")
TABLE_PREFIX=$(jq -r '.source.db.table_prefix' "$CONFIG")

TARGET_CONTAINER=$(jq -r '.target.container' "$CONFIG")
TARGET_DB=$(jq -r '.target.db.database' "$CONFIG")
TARGET_USER=$(jq -r '.target.db.user' "$CONFIG")
TARGET_PASS_ENV=$(jq -r '.target.db.password_env' "$CONFIG")
WEBSITE_ID=$(jq -r '.target.website_id' "$CONFIG")
HOSTNAME=$(jq -r '.target.hostname' "$CONFIG")

DATE_FROM=$(jq -r '.strategy.date_from' "$CONFIG")
DATE_TO=$(jq -r '.strategy.date_to' "$CONFIG")
BATCH_SIZE=$(jq -r '.strategy.batch_size' "$CONFIG")

# ── Load source/target secrets (from deployed .secrets files) ────────
# build.sh deploys these alongside docker-compose.yml per service.
MATOMO_SECRETS="/opt/containers/matomo/.secrets"
UMAMI_SECRETS="/opt/containers/umami/.secrets"
[ -f "$MATOMO_SECRETS" ] || { echo "[migrate] FATAL: $MATOMO_SECRETS missing" >&2; exit 1; }
[ -f "$UMAMI_SECRETS" ]  || { echo "[migrate] FATAL: $UMAMI_SECRETS missing" >&2; exit 1; }

# shellcheck disable=SC1090
. "$MATOMO_SECRETS"
SOURCE_PASS=$(eval "printf '%s' \"\$$SOURCE_PASS_ENV\"")
# shellcheck disable=SC1090
. "$UMAMI_SECRETS"
TARGET_PASS=$(eval "printf '%s' \"\$$TARGET_PASS_ENV\"")

[ -n "$SOURCE_PASS" ] || { echo "[migrate] FATAL: source password missing ($SOURCE_PASS_ENV)" >&2; exit 1; }
[ -n "$TARGET_PASS" ] || { echo "[migrate] FATAL: target password missing ($TARGET_PASS_ENV)" >&2; exit 1; }

log() { printf '[migrate %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

WORK=$(mktemp -d -t migrate-matomo-umami.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
log "Workdir: $WORK"
log "Date range: $DATE_FROM .. $DATE_TO"
log "Source: $SOURCE_CONTAINER/$SOURCE_DB  ->  Target: $TARGET_CONTAINER/$TARGET_DB (website=$WEBSITE_ID)"

# ── Step 1: EXTRACT — dump joined matomo rows as TSV ─────────────────
EXPORT_TSV="$WORK/matomo-export.tsv"

# Query joins visits + actions + URL/title lookups. NULL-safe (COALESCE).
# Fields (tab-separated): idvisit, idlink_va, visit_first_action_time, server_time,
#                          visitor_id(hex), user_agent, config_browser_name,
#                          config_os, config_device_type, config_resolution,
#                          location_browser_lang, location_country,
#                          location_region, location_city, url_name, page_title,
#                          referrer_url, config_device_brand, config_device_model
MATOMO_QUERY="
SELECT
  lv.idvisit,
  lvla.idlink_va,
  lv.visit_first_action_time,
  lvla.server_time,
  HEX(lv.idvisitor) AS visitor_id,
  COALESCE(lv.config_browser_name,'') AS browser,
  COALESCE(lv.config_os,'') AS os,
  COALESCE(lv.config_device_type,'') AS device,
  CONCAT(COALESCE(lv.config_resolution,''),'') AS screen,
  COALESCE(lv.location_browser_lang,'') AS lang,
  COALESCE(lv.location_country,'') AS country,
  COALESCE(lv.location_region,'') AS region,
  COALESCE(lv.location_city,'') AS city,
  COALESCE(a1.name,'/') AS url_name,
  COALESCE(a2.name,'') AS page_title,
  COALESCE(lv.referer_url,'') AS referrer_url
FROM ${TABLE_PREFIX}log_visit lv
JOIN ${TABLE_PREFIX}log_link_visit_action lvla ON lv.idvisit = lvla.idvisit
LEFT JOIN ${TABLE_PREFIX}log_action a1 ON lvla.idaction_url  = a1.idaction
LEFT JOIN ${TABLE_PREFIX}log_action a2 ON lvla.idaction_name = a2.idaction
WHERE lvla.server_time BETWEEN '${DATE_FROM} 00:00:00' AND '${DATE_TO} 23:59:59'
ORDER BY lvla.server_time
"

log "Step 1/4: extracting from matomo..."
docker exec -i "$SOURCE_CONTAINER" \
    mysql -u"$SOURCE_USER" -p"$SOURCE_PASS" -B -N --default-character-set=utf8mb4 "$SOURCE_DB" \
    -e "$MATOMO_QUERY" > "$EXPORT_TSV"

ROW_COUNT=$(wc -l < "$EXPORT_TSV")
log "Extracted $ROW_COUNT rows to $EXPORT_TSV"

if [ "$ROW_COUNT" -eq 0 ]; then
    log "No rows to migrate. Done."
    exit 0
fi

# Also emit JSON audit trail (per FIRE rule #4: testable record of what was imported)
EXPORT_JSON="$WORK/matomo-export.json"
awk -F'\t' 'BEGIN{print "["} NR>1{print ","} {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
    printf "{\"idvisit\":\"%s\",\"idlink_va\":\"%s\",\"visit_first\":\"%s\",\"server_time\":\"%s\",\"visitor_id\":\"%s\",\"browser\":\"%s\",\"os\":\"%s\",\"device\":\"%s\",\"screen\":\"%s\",\"lang\":\"%s\",\"country\":\"%s\",\"region\":\"%s\",\"city\":\"%s\",\"url\":\"%s\",\"title\":\"%s\",\"referrer\":\"%s\"}",
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16
} END{print "]"}' "$EXPORT_TSV" > "$EXPORT_JSON"

# Persist audit trail alongside migration dir
mkdir -p "$SELF_DIR/exports"
AUDIT="$SELF_DIR/exports/export-$(date +%Y%m%dT%H%M%S).json"
cp "$EXPORT_JSON" "$AUDIT"
log "Audit trail written to $AUDIT"

# ── Step 2: TRANSFORM — build Umami SQL (sessions + events) ──────────
log "Step 2/4: transforming to Umami schema..."
IMPORT_SQL="$WORK/umami-import.sql"

# Deterministic UUID from any string: md5 hash -> format as UUID v4-ish
# This makes the migration idempotent: same matomo row -> same umami UUID.
# Use printf + md5sum (coreutils on oci-apps) to avoid extra deps.
awk -F'\t' -v ws="$WEBSITE_ID" -v hn="$HOSTNAME" '
function _md5(s,    cmd,line) {
    cmd = "printf %s " "\047" s "\047" " | md5sum | cut -c1-32"
    cmd | getline line
    close(cmd)
    return line
}
function _uuid(prefix, key,    h) {
    h = _md5(prefix ":" key)
    return substr(h,1,8) "-" substr(h,9,4) "-" substr(h,13,4) "-" substr(h,17,4) "-" substr(h,21,12)
}
function sq(s) {
    gsub(/'\''/, "'\'''\''", s); return s
}
function trim_screen(s,   m) {
    # matomo resolution is like "1920x1080" - fits in varchar(11). Keep as-is, clip just in case.
    return substr(s, 1, 11)
}
function trim_lang(s) { return substr(s, 1, 35) }
function trim_country(s,   c) {
    c = toupper(substr(s, 1, 2))
    if (c ~ /^[A-Z][A-Z]$/) return c
    return ""
}
function trim_path(s,   p,q,qpos) {
    # Matomo stores full URL in action.name; Umami needs url_path (path only).
    # Strip protocol+host: take everything after first "/" past "://".
    if (substr(s, 1, 4) == "http") {
        qpos = index(s, "://")
        if (qpos > 0) {
            s = substr(s, qpos + 3)
            qpos = index(s, "/")
            if (qpos > 0) s = substr(s, qpos)
            else s = "/"
        }
    }
    # Split query
    qpos = index(s, "?")
    if (qpos > 0) {
        p = substr(s, 1, qpos - 1)
        q = substr(s, qpos + 1)
    } else { p = s; q = "" }
    if (length(p) == 0) p = "/"
    return substr(p, 1, 500) "\t" substr(q, 1, 500)
}
function ref_host(s,   p) {
    if (s == "") return ""
    if (substr(s, 1, 4) == "http") {
        p = substr(s, index(s, "://") + 3)
        p = substr(p, 1, index(p "/", "/") - 1)
        return substr(p, 1, 500)
    }
    return ""
}
BEGIN {
    print "BEGIN;"
    print "-- Matomo -> Umami migration (deterministic UUIDs, ON CONFLICT DO NOTHING)"
}
{
    idvisit     = $1
    idlink_va   = $2
    visit_first = $3
    server_time = $4
    visitor_id  = $5
    # Umami v1 schema: browser/os/device are varchar(20) — clip accordingly
    browser     = sq(substr($6, 1, 20))
    os          = sq(substr($7, 1, 20))
    device      = sq(substr($8, 1, 20))
    screen      = trim_screen($9)
    lang        = trim_lang(sq($10))
    country     = trim_country($11)
    region      = sq(substr($12, 1, 20))
    city        = sq(substr($13, 1, 50))
    url_raw     = $14
    title       = sq(substr($15, 1, 500))
    referrer    = $16

    # UUID generation — namespaced by matomo-umami to avoid collision with native Umami rows
    session_id  = _uuid("mu-sess", idvisit)
    event_id    = _uuid("mu-event", idlink_va)
    visit_id    = _uuid("mu-visit", idvisit)
    distinct_id = substr(_md5("mu-dist:" visitor_id), 1, 50)

    # Split URL into path + query
    split(trim_path(url_raw), parts, "\t")
    url_path  = sq(parts[1])
    url_query = sq(parts[2])

    ref_path  = ""
    ref_query = ""
    ref_dom   = sq(ref_host(referrer))

    # session: schema has session_id, website_id, browser, os, device, screen, language,
    # country, region, city, created_at, distinct_id (no hostname, no subdivision1/2).
    printf "INSERT INTO session (session_id, website_id, browser, os, device, screen, language, country, region, city, distinct_id, created_at) VALUES ('\''%s'\'', '\''%s'\'', NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), '\''%s'\'') ON CONFLICT (session_id) DO NOTHING;\n", \
        session_id, ws, browser, os, device, screen, lang, country, region, city, distinct_id, visit_first

    # website_event: schema has event_id, website_id, session_id, created_at, url_path,
    # url_query, referrer_path, referrer_query, referrer_domain, page_title, event_type,
    # event_name, visit_id, tag, hostname (browser/os/device/etc live on session, not event).
    # tag="matomo-import" marks rows for the parity test — distinguishes migrated from live.
    printf "INSERT INTO website_event (event_id, website_id, session_id, visit_id, created_at, url_path, url_query, referrer_path, referrer_query, referrer_domain, page_title, event_type, event_name, tag, hostname) VALUES ('\''%s'\'', '\''%s'\'', '\''%s'\'', '\''%s'\'', '\''%s'\'', '\''%s'\'', NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), NULLIF('\''%s'\'','\'''\''), 1, NULL, '\''matomo-import'\'', '\''%s'\'') ON CONFLICT (event_id) DO UPDATE SET tag = EXCLUDED.tag;\n", \
        event_id, ws, session_id, visit_id, server_time, url_path, url_query, ref_path, ref_query, ref_dom, title, hn
}
END {
    print "COMMIT;"
}
' "$EXPORT_TSV" > "$IMPORT_SQL"

SQL_LINES=$(wc -l < "$IMPORT_SQL")
log "Generated $SQL_LINES SQL statements in $IMPORT_SQL"

# ── Step 3: IMPORT — pipe SQL to umami-db via psql ───────────────────
log "Step 3/4: importing into umami-db..."
# docker cp then psql -f — keeps script out of process args (which would hit argv limits)
docker cp "$IMPORT_SQL" "$TARGET_CONTAINER":/tmp/umami-import.sql
docker exec -i "$TARGET_CONTAINER" \
    env PGPASSWORD="$TARGET_PASS" \
    psql -U "$TARGET_USER" -d "$TARGET_DB" -v ON_ERROR_STOP=1 -f /tmp/umami-import.sql > "$WORK/psql.out" 2>&1 || {
        echo "[migrate] IMPORT FAILED — last 40 lines:" >&2
        tail -40 "$WORK/psql.out" >&2
        exit 1
    }
docker exec "$TARGET_CONTAINER" rm -f /tmp/umami-import.sql || true

INSERT_COUNT=$(grep -c '^INSERT' "$WORK/psql.out" 2>/dev/null || echo 0)
log "psql reported $INSERT_COUNT inserts"

# ── Step 4: VERIFY — row counts ──────────────────────────────────────
log "Step 4/4: verifying parity..."
SOURCE_CNT=$(docker exec -i "$SOURCE_CONTAINER" \
    mysql -u"$SOURCE_USER" -p"$SOURCE_PASS" -B -N "$SOURCE_DB" \
    -e "SELECT COUNT(*) FROM ${TABLE_PREFIX}log_link_visit_action WHERE server_time BETWEEN '${DATE_FROM} 00:00:00' AND '${DATE_TO} 23:59:59'")
TARGET_CNT=$(docker exec -i "$TARGET_CONTAINER" \
    env PGPASSWORD="$TARGET_PASS" \
    psql -U "$TARGET_USER" -d "$TARGET_DB" -tAc \
    "SELECT COUNT(*) FROM website_event WHERE website_id = '$WEBSITE_ID' AND created_at BETWEEN '${DATE_FROM} 00:00:00' AND '${DATE_TO} 23:59:59'")

log "========================================"
log " Matomo rows  (source): $SOURCE_CNT"
log " Umami  rows  (target): $TARGET_CNT"
log " Audit JSON          : $AUDIT"
log "========================================"

# Final test delegated to test.sh — it reads config tolerance and exits non-zero on drift.
"$SELF_DIR/test.sh"
