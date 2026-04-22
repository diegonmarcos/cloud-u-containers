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

MBOXES="$(docker exec maddy maddy imap-mboxes list "$ACCOUNT" 2>/dev/null | awk -v re="$REGEX" '$0 ~ re { print $0 }' || true)"

if [ -z "$MBOXES" ]; then
    echo "[cleanup] no mailboxes matched — nothing to do"
    exit 0
fi

echo "[cleanup] will drop:"
printf '  %s\n' $MBOXES

printf '%s\n' "$MBOXES" | while IFS= read -r mbox; do
    [ -z "$mbox" ] && continue
    echo "[cleanup] removing: $mbox"
    docker exec maddy maddy imap-mboxes remove "$ACCOUNT" "$mbox" || \
        echo "[cleanup] WARN: remove failed for: $mbox" >&2
done

echo "[cleanup] done"
