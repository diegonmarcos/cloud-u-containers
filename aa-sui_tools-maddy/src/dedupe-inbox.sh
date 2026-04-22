#!/bin/sh
# Maddy: collapse INBOX into the 7 emoji folders + dedupe by Message-ID.
#
# Runs on the VM host (via `build.sh dedupe` → lifecycle ssh_run).
#
# Contract:
#   - mail-rules.json is source of truth for the domain→folder routing.
#   - The 7 destination folders are `.routing[].folder ∪ .routing_default`.
#   - For every message in INBOX:
#       * decide target folder from its From header (falls back to
#         routing_default when no rule matches);
#       * if the same Message-ID already exists in the target folder,
#         DELETE the INBOX copy (duplicate);
#       * otherwise, MOVE to target.
#   - INBOX ends empty; each target folder holds at most one copy per
#     Message-ID.
#
# After this runs, a follow-up pass dedupes within each target folder
# (same Message-ID across pre-existing and newly moved messages).
#
# Batched: one `maddy imap-msgs move` call per (target folder) rather
# than per message. Without batching this scales at ~50ms × 36k = 30min.
set -eu

ACCT="$(docker exec maddy jq -r '.account // empty' /data/mail-rules.json)"
DEFAULT="$(docker exec maddy jq -r '.routing_default // empty' /data/mail-rules.json)"
[ -n "$ACCT" ]    || { echo "[dedupe] .account missing"    >&2; exit 1; }
[ -n "$DEFAULT" ] || { echo "[dedupe] .routing_default missing" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[dedupe] account=$ACCT  default=$DEFAULT"

# ── 1. Dump routing table to jq-parseable form once ──────────────────────
docker exec maddy jq -r '.routing[] | .folder as $f | .match.values[] | "\(.)\t\($f)"' \
    /data/mail-rules.json > "$TMP/routing.tsv"

# ── 2. Build index of Message-IDs already present in each emoji folder ──
: > "$TMP/existing.tsv"   # cols: msgid \t folder
# Folders = unique values of routing[].folder ∪ routing_default
docker exec maddy jq -r '[.routing[].folder, .routing_default] | unique | .[]' \
    /data/mail-rules.json > "$TMP/folders.txt"

while IFS= read -r fld; do
    [ -z "$fld" ] && continue
    docker exec maddy maddy imap-msgs list -u --full "$ACCT" "$fld" 2>/dev/null \
        | awk -v f="$fld" '
            /^UID: / { msgid="" }
            /^Message-Id: / { msgid=$2; gsub(/[<>]/,"",msgid) }
            /^Subject: / && msgid!="" { print msgid "\t" f; msgid="" }
        ' >> "$TMP/existing.tsv" || true
    n=$(awk -v f="$fld" '$2==f' "$TMP/existing.tsv" | wc -l)
    printf '[dedupe]   existing in %-30s %s\n' "$fld" "$n"
done < "$TMP/folders.txt"

# ── 3. Enumerate INBOX: uid | msgid | from_domain ──────────────────────
echo "[dedupe] scanning INBOX..."
docker exec maddy maddy imap-msgs list -u --full "$ACCT" "INBOX" 2>/dev/null \
    | awk '
        /^UID: / { uid=$2; msgid=""; fromd="" }
        /^Message-Id: / { msgid=$2; gsub(/[<>]/,"",msgid) }
        /^From: / {
            line=$0
            if (match(line,/<[^@<>]+@[^<>]+>/)) {
                a=substr(line,RSTART+1,RLENGTH-2); sub(/.*@/,"",a); fromd=tolower(a)
            } else if (match(line,/[^ <]+@[^ <>]+/)) {
                a=substr(line,RSTART,RLENGTH); sub(/.*@/,"",a); sub(/[>,;"].*/,"",a); fromd=tolower(a)
            }
        }
        /^Subject: / && uid!="" {
            printf "%s\t%s\t%s\n", uid, msgid, fromd
            uid=""
        }
    ' > "$TMP/inbox.tsv"

INBOX_TOTAL=$(wc -l < "$TMP/inbox.tsv")
echo "[dedupe] INBOX msgs: $INBOX_TOTAL"

# ── 4. Decide per-message action ──────────────────────────────────────
# Out: $TMP/plan.tsv = action \t target \t uid \t msgid
awk -F '\t' -v def="$DEFAULT" '
    FNR==NR && FILENAME ~ /routing.tsv$/  { route[$1]=$2; next }
    FNR==NR && FILENAME ~ /existing.tsv$/ { key=$1 "\t" $2; have[key]=1; next }
    {
        uid=$1; msgid=$2; dom=$3
        tgt = (dom in route ? route[dom] : def)
        if (msgid != "" && ((msgid "\t" tgt) in have))
            printf "DEL\t%s\t%s\t%s\n", tgt, uid, msgid
        else
            printf "MOVE\t%s\t%s\t%s\n", tgt, uid, msgid
    }
' "$TMP/routing.tsv" "$TMP/existing.tsv" "$TMP/inbox.tsv" > "$TMP/plan.tsv"

DEL_N=$(awk '$1=="DEL"' "$TMP/plan.tsv" | wc -l)
MOV_N=$(awk '$1=="MOVE"' "$TMP/plan.tsv" | wc -l)
echo "[dedupe] plan: $DEL_N delete (dup), $MOV_N move"

# ── 5. Execute per-target batches ────────────────────────────────────
# SEQSET supports comma-separated UIDs. maddy imap-msgs move takes
# SRCMBOX SEQSET TGTMBOX.
execute_batch() {
    _action="$1"; _target="$2"; _uids="$3"
    [ -z "$_uids" ] && return 0
    case "$_action" in
        MOVE)
            echo "[dedupe] MOVE $(echo "$_uids" | awk -F, '{print NF}') → $_target"
            docker exec maddy maddy imap-msgs move -u "$ACCT" "INBOX" "$_uids" "$_target" \
                2>&1 | tail -3 || echo "[dedupe] WARN: move to $_target failed" >&2
            ;;
        DEL)
            echo "[dedupe] DEL $(echo "$_uids" | awk -F, '{print NF}') (dup of $_target)"
            docker exec maddy maddy imap-msgs remove -u "$ACCT" "INBOX" "$_uids" \
                2>&1 | tail -3 || echo "[dedupe] WARN: remove failed" >&2
            ;;
    esac
}

# Group plan by (action, target) and batch UIDs.
# Chunk size limit: 2000 UIDs per call to keep argv size safe.
awk -F '\t' '{
    key=$1 "|" $2
    if (!(key in buf)) buf[key]=""
    buf[key]=(buf[key]==""? $3 : buf[key] "," $3)
    cnt[key]++
    if (cnt[key] >= 2000) {
        print key "\t" buf[key]
        buf[key]=""
        cnt[key]=0
    }
}
END {
    for (k in buf) if (buf[k] != "") print k "\t" buf[k]
}' "$TMP/plan.tsv" > "$TMP/batches.tsv"

BATCHES=$(wc -l < "$TMP/batches.tsv")
echo "[dedupe] executing $BATCHES batches..."

while IFS="$(printf '\t')" read -r keypair uids; do
    action="${keypair%%|*}"
    target="${keypair#*|}"
    execute_batch "$action" "$target" "$uids"
done < "$TMP/batches.tsv"

echo "[dedupe] done"
