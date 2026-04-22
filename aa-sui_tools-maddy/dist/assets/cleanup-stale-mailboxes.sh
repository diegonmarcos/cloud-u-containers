#!/bin/sh
# Maddy: drop legacy IMAP mailboxes left by the retired imap-sorter.py.
# Runs on the VM host (via `build.sh cleanup` → lifecycle ssh_run).
# Declarative: regex + account sourced from /data/mail-rules.json inside the
# maddy container. No hardcoded folder names.
set -eu

REGEX="$(docker exec maddy jq -r '.cleanup.drop_name_regex // empty' /data/mail-rules.json)"
ACCOUNT="$(docker exec maddy jq -r '.account // empty' /data/mail-rules.json)"

if [ -z "$REGEX" ] || [ -z "$ACCOUNT" ]; then
    echo "[cleanup] mail-rules.json missing .cleanup.drop_name_regex or .account — aborting" >&2
    exit 1
fi

echo "[cleanup] account=$ACCOUNT  drop_name_regex=$REGEX"

# Output of `maddy imap-mboxes list` is TSV: "<name>\t[<flags>]". Take the
# first field only. Sort reverse so IMAP children (e.g. "1-…1-2…") drop
# before their parents ("1-…") — otherwise IMAP refuses to remove a
# non-empty hierarchy node.
MBOXES="$(docker exec maddy maddy imap-mboxes list "$ACCOUNT" 2>/dev/null \
    | awk -F '\t' -v re="$REGEX" '$1 ~ re { print $1 }' \
    | sort -r || true)"

if [ -z "$MBOXES" ]; then
    echo "[cleanup] no mailboxes matched — nothing to do"
    exit 0
fi

COUNT=$(printf '%s\n' "$MBOXES" | wc -l)
echo "[cleanup] will drop $COUNT mailboxes"

printf '%s\n' "$MBOXES" | while IFS= read -r mbox; do
    [ -z "$mbox" ] && continue
    echo "[cleanup] removing: $mbox"
    docker exec maddy maddy imap-mboxes remove --yes "$ACCOUNT" "$mbox" 2>&1 || \
        echo "[cleanup] WARN: remove failed for: $mbox" >&2
done

echo "[cleanup] done"
