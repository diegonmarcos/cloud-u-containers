#!/usr/bin/env python3
"""
count_recent.py — read-only: count Gmail messages received since a given
timestamp, via the Gmail REST API (gmail.readonly), impersonating the
target user through the existing domain-wide-delegation service account.
Not an MCP tool (this module isn't imported by main.py) — a one-off
operator/CI script, same shape as
../../../../infra-api_mail-mcp/src/code/mcp/tools/others/gws_missing_backfill.py
(which reads Gmail the identical way for the backfill tool).

Why this exists: cross-store mail-health reconciliation
(1_cicd/src/ops/cloud-health-mail-full.sh) — Gmail is the authoritative
primary inbox; comparing its recent-message count against maddy/Stalwart
(see the sibling count-since.ts) catches a store silently falling behind,
which the liveness-only cloud-mail-health-full Rust derive does not.

Auth: service account key at /run/secrets/service-account-key.json (the
same path gws_missing_backfill.py uses — see google-workspace-mcp's
compose.nix, which bind-mounts .secrets.d/GOOGLE_SERVICE_ACCOUNT_KEY there),
domain-wide delegation impersonating --user (default me@diegonmarcos.com),
scope gmail.readonly. No app password, no interactive consent.

Counting: paginates messages.list with q="after:<epoch_seconds>" and sums
page sizes exactly (NOT resultSizeEstimate, which Gmail documents as
approximate) so the count is precise enough for a tight tolerance check.

RUN — inside the google-workspace-mcp container, same invocation shape as
gws_missing_backfill.py:

  docker cp count_recent.py google-workspace-mcp:/tmp/count_recent.py
  docker exec google-workspace-mcp /app/.venv/bin/python /tmp/count_recent.py \
    --since 2026-08-21T00:00:00Z

Prints a single integer (message count) to stdout on success; nonzero exit
+ message on stderr on failure.
"""
import argparse
import sys
from datetime import datetime, timezone

from google.oauth2 import service_account
from google.auth.transport.requests import Request
from googleapiclient.discovery import build

SA_KEY = "/run/secrets/service-account-key.json"


def gmail_service(user: str):
    creds = service_account.Credentials.from_service_account_file(
        SA_KEY, scopes=["https://www.googleapis.com/auth/gmail.readonly"], subject=user
    )
    creds.refresh(Request())
    return build("gmail", "v1", credentials=creds, cache_discovery=False)


def count_since(svc, epoch_seconds: int) -> int:
    total = 0
    req = svc.users().messages().list(userId="me", q=f"after:{epoch_seconds}", maxResults=500)
    while req is not None:
        resp = req.execute()
        total += len(resp.get("messages", []))
        req = svc.users().messages().list_next(req, resp)
    return total


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True, help="ISO8601 timestamp, e.g. 2026-08-21T00:00:00Z")
    ap.add_argument("--user", default="me@diegonmarcos.com")
    args = ap.parse_args()

    try:
        since_dt = datetime.fromisoformat(args.since.replace("Z", "+00:00"))
    except ValueError:
        print(f"invalid --since date: {args.since}", file=sys.stderr)
        sys.exit(2)

    epoch = int(since_dt.astimezone(timezone.utc).timestamp())

    try:
        svc = gmail_service(args.user)
        n = count_since(svc, epoch)
    except Exception as e:  # noqa: BLE001 — surface any auth/API failure to the caller
        print(f"gmail count failed: {e}", file=sys.stderr)
        sys.exit(1)

    print(n)


if __name__ == "__main__":
    main()
