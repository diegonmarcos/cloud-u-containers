#!/bin/sh
# Maddy phase-2 dedupe: within each routing folder + INBOX, keep exactly one
# copy per Message-ID (the lowest UID), delete the rest.
#
# Runs on the VM host via `build.sh dedupe-folders` lifecycle.
#
# Data source: /data/mail-rules.json — folders = .routing[].folder ∪ .routing_default ∪ INBOX.
# Batch size kept low (300 UIDs/call) to stay under docker exec argv limits.
set -eu

ACCT="$(docker exec maddy jq -r '.account // empty' /data/mail-rules.json)"
[ -n "$ACCT" ] || { echo "[dedupe2] .account missing" >&2; exit 1; }

# All target folders + INBOX (so surviving INBOX msgs also dedupe against self).
FOLDERS=$(docker exec maddy jq -r '[.routing[].folder, .routing_default, "INBOX"] | unique | .[]' \
    /data/mail-rules.json)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CHUNK=300
TOTAL_DEL=0

echo "$FOLDERS" | while IFS= read -r FLD; do
    [ -z "$FLD" ] && continue

    DUMP="$TMP/dump.tsv"
    DUPS="$TMP/dups.txt"

    # List UID + Message-Id (one per msg). Subject triggers record emit so
    # messages with no Subject are skipped — they'd also be skipped in the
    # first pass; impact is negligible.
    docker exec maddy maddy imap-msgs list -u --full "$ACCT" "$FLD" 2>/dev/null \
        | awk '
            /^UID: / { uid=$2; msgid=""; have_sub=0 }
            /^Message-Id: / { msgid=$2; gsub(/[<>]/,"",msgid) }
            /^Subject: / && uid!="" && !have_sub {
                print uid "\t" msgid
                have_sub=1; uid=""
            }
        ' > "$DUMP"

    TOTAL=$(wc -l < "$DUMP" | tr -d ' ')

    # Group by msgid, keep lowest UID numerically, emit the rest for delete.
    # UIDs are already listed in ascending order by maddy, so first occurrence
    # per msgid is the keeper.
    awk -F '\t' '
        $2=="" { next }
        { if ($2 in kept) print $1; else kept[$2]=$1 }
    ' "$DUMP" > "$DUPS"

    N=$(wc -l < "$DUPS" | tr -d ' ')
    if [ "$N" -eq 0 ]; then
        printf '[dedupe2] %-30s %6d msgs  0 dups\n' "$FLD" "$TOTAL"
        continue
    fi
    printf '[dedupe2] %-30s %6d msgs  %d dups → delete\n' "$FLD" "$TOTAL" "$N"

    # Chunked delete. Can't trust argv for very long SEQSETs.
    split -l "$CHUNK" "$DUPS" "$TMP/chunk_"
    for chunk in "$TMP/chunk_"*; do
        [ -s "$chunk" ] || continue
        seq=$(paste -sd, "$chunk")
        docker exec maddy maddy imap-msgs remove -u "$ACCT" "$FLD" "$seq" 2>&1 | tail -1 || \
            echo "[dedupe2] WARN: chunk remove failed on $FLD" >&2
    done
    rm -f "$TMP/chunk_"*

    TOTAL_DEL=$((TOTAL_DEL + N))
done

echo "[dedupe2] done"
