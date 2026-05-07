#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Migration parity test                                            ║
# ║                                                                  ║
# ║ Compares Matomo source-of-truth row counts to Umami target       ║
# ║ row counts over the configured date range. Fails (exit 1) if     ║
# ║ drift exceeds tolerance_pct in config.json.                      ║
# ║                                                                  ║
# ║ Per FIRE rule #4: no task complete without a tester.             ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SELF_DIR/config.json"

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

DATE_FROM=$(jq -r '.strategy.date_from' "$CONFIG")
DATE_TO=$(jq -r '.strategy.date_to' "$CONFIG")
TOLERANCE=$(jq -r '.test.tolerance_pct' "$CONFIG")

# shellcheck disable=SC1091
. /opt/containers/matomo/.secrets
SOURCE_PASS=$(eval "printf '%s' \"\$$SOURCE_PASS_ENV\"")
# shellcheck disable=SC1091
. /opt/containers/umami/.secrets
TARGET_PASS=$(eval "printf '%s' \"\$$TARGET_PASS_ENV\"")

log() { printf '[test %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Source count
SRC=$(docker exec -i "$SOURCE_CONTAINER" \
    mysql -u"$SOURCE_USER" -p"$SOURCE_PASS" -B -N "$SOURCE_DB" \
    -e "SELECT COUNT(*) FROM ${TABLE_PREFIX}log_link_visit_action WHERE server_time BETWEEN '${DATE_FROM} 00:00:00' AND '${DATE_TO} 23:59:59'")

# Target count — ONLY migrated rows (tag='matomo-import'), so live tracking doesn't skew parity
TGT=$(docker exec -i "$TARGET_CONTAINER" \
    env PGPASSWORD="$TARGET_PASS" \
    psql -U "$TARGET_USER" -d "$TARGET_DB" -tAc \
    "SELECT COUNT(*) FROM website_event WHERE website_id = '$WEBSITE_ID' AND tag = 'matomo-import' AND created_at BETWEEN '${DATE_FROM} 00:00:00' AND '${DATE_TO} 23:59:59'")

log "Source (Matomo): $SRC"
log "Target (Umami):  $TGT"

# Monthly breakdown — helps pinpoint partial imports
log "Monthly comparison:"
docker exec -i "$SOURCE_CONTAINER" \
    mysql -u"$SOURCE_USER" -p"$SOURCE_PASS" -B -N "$SOURCE_DB" \
    -e "SELECT DATE_FORMAT(server_time,'%Y-%m') AS m, COUNT(*) FROM ${TABLE_PREFIX}log_link_visit_action WHERE server_time BETWEEN '${DATE_FROM} 00:00:00' AND '${DATE_TO} 23:59:59' GROUP BY m ORDER BY m" > /tmp/mcount.tsv

docker exec -i "$TARGET_CONTAINER" \
    env PGPASSWORD="$TARGET_PASS" \
    psql -U "$TARGET_USER" -d "$TARGET_DB" -tAc \
    "SELECT to_char(created_at,'YYYY-MM') AS m, COUNT(*) FROM website_event WHERE website_id = '$WEBSITE_ID' AND tag = 'matomo-import' AND created_at BETWEEN '${DATE_FROM} 00:00:00' AND '${DATE_TO} 23:59:59' GROUP BY m ORDER BY m" \
    | tr '|' '\t' > /tmp/ucount.tsv

awk -F'\t' 'FNR==NR{m[$1]=$2;next}{printf "  %-10s matomo=%-6s umami=%-6s diff=%+d\n", $1, m[$1], $2, $2-m[$1]; delete m[$1]} END{for (k in m) printf "  %-10s matomo=%-6s umami=0      diff=%+d\n", k, m[k], -m[k]}' \
    /tmp/mcount.tsv /tmp/ucount.tsv | sort

# Verdict
if [ "$SRC" -eq 0 ]; then
    log "No source rows — nothing to compare."
    exit 0
fi
DIFF=$((SRC - TGT))
[ $DIFF -lt 0 ] && DIFF=$((-DIFF))
PCT=$((DIFF * 100 / SRC))
log "Drift: $DIFF rows ($PCT%), tolerance: $TOLERANCE%"
if [ "$PCT" -gt "$TOLERANCE" ]; then
    log "FAIL: drift exceeds tolerance"
    exit 1
fi
log "PASS: parity within tolerance"
