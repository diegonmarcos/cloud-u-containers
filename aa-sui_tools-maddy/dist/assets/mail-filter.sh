#!/bin/sh
# Maddy imap_filter.command — delivery-time router (POSIX sh, busybox-safe).
# Contract (maddy internal/imap_filter/command/command.go):
#   stdin        : RFC822 message bytes
#   argv         : {account_name} {sender} {rcpt_to} {subject}
#   stdout line 1: destination folder (empty → INBOX)
#
# Maddy has no Sieve and no tag/keyword system. This is pure MOVE: one
# from-domain match → one destination folder. Rules live in mail-rules.json.
# Stalwart uses a different (Sieve+tag) schema and is NOT shared.
set -eu

RULES="${RULES_PATH:-/data/mail-rules.json}"
SENDER="${2:-}"

# Capture stdin once (we only need the header block).
HEADERS="$(awk 'BEGIN{RS="";ORS=""} NR==1{print;exit}')"

# Extract From: header (case-insensitive match, handle folded lines).
FROM_HDR="$(printf '%s\n' "$HEADERS" | awk '
    tolower($0) ~ /^from:[ \t]/ { sub(/^[Ff][Rr][Oo][Mm]:[ \t]*/,""); print; exit }
')"

# Address inside < > or first token containing @, else fall back to envelope sender.
FROM_ADDR="$(printf '%s\n' "${FROM_HDR:-$SENDER}" | awk '
    {
      if (match($0,/<[^>]+>/)) { print substr($0,RSTART+1,RLENGTH-2); exit }
      for (i=1;i<=NF;i++) if ($i ~ /@/) { gsub(/[<>,;"]/,"",$i); print $i; exit }
    }
')"

FROM_DOMAIN="$(printf '%s' "${FROM_ADDR##*@}" | tr '[:upper:]' '[:lower:]')"

# Declarative lookup: jq returns the matching folder or the default.
FOLDER="$(jq -r --arg d "$FROM_DOMAIN" '
    (first(.routing[]?
           | select(.match.type=="from_domain"
                    and (.match.values|index($d))) ).folder)
    // .routing_default // ""
' "$RULES" 2>/dev/null || printf '')"

printf '%s\n' "$FOLDER"
