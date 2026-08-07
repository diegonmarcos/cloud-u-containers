#!/usr/bin/env python3
"""
gws_missing_backfill.py — one-shot: copy ONLY the messages that exist in a
Google Workspace mailbox but are MISSING from Stalwart. Dedup by Message-ID
across EVERY Stalwart folder, so nothing already present is re-copied — zero
duplicates. Safe to re-run and safe to run alongside maddy's live dual-write.

Why this lives here: the primary inbound path is CF Email Routing -> Worker
`email-forwarder` -> maddy:25, which dual-writes to Stalwart (JMAP/IMAP store)
AND imports into Google Workspace. This tool is the BACKFILL half — it pulls
the historical Workspace mail that predates the dual-write into Stalwart.
It is NOT part of the steady-state flow; run it by hand for a one-time sync.

Access model (no app-password, no user consent):
  The Google Workspace domain has a service account with domain-wide
  delegation (diego-cli@diegonmarcos-infra-prod). Mint a short-lived Gmail
  IMAP access token that impersonates the target user, then IMAP-XOAUTH2 into
  imap.gmail.com. The SA private key never leaves its container:

    TOKEN=$(ssh oci-apps "docker exec google-workspace-mcp \\
      /app/.venv/bin/python -c \"
    from google.oauth2 import service_account
    from google.auth.transport.requests import Request
    c = service_account.Credentials.from_service_account_file(
        '/run/secrets/service-account-key.json',
        scopes=['https://mail.google.com/'], subject='me@diegonmarcos.com')
    c.refresh(Request()); print(c.token)\"")

Run from a host that reaches BOTH imap.gmail.com (internet) and Stalwart's WG
IMAP (10.0.0.3:2993) — e.g. oci-mail:

    python3 gws_missing_backfill.py <GMAIL_ACCESS_TOKEN> <STALWART_PASSWORD> [SRC_MAILBOX]

  SRC_MAILBOX default: "[Gmail]/All Mail" (the complete archive). Missing
  messages are APPENDed to Stalwart INBOX with their original INTERNALDATE and
  the \\Seen flag (historical mail, not shown as unread).

Notes:
  - USER / STALW below assume me@diegonmarcos.com on Stalwart 10.0.0.3:2993.
    Adjust for another account/host.
  - Stalwart's per-account auth rate-limit bans after a few auths in a short
    window; this tool uses a SINGLE Stalwart login with backoff retry to stay
    under it. Avoid hammering the account with other IMAP logins while it runs.
"""
import imaplib, ssl, sys, email, time

USER = "me@diegonmarcos.com"
GMAIL = ("imap.gmail.com", 993)
STALW = ("10.0.0.3", 2993)
TOKEN = sys.argv[1]
PASSWORD = sys.argv[2]
SRC_MB = sys.argv[3] if len(sys.argv) > 3 else "[Gmail]/All Mail"

imaplib._MAXLINE = 10_000_000
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE

def stalwart_login(retries=8, wait=45):
    """Single Stalwart connection with backoff — survives the per-account
    auth rate-limit (bans after a few auths in a short window)."""
    last = None
    for a in range(retries):
        try:
            c = imaplib.IMAP4_SSL(*STALW, ssl_context=ctx)
            c.login(USER, PASSWORD)
            return c
        except Exception as e:
            last = e
            print(f"  stalwart login attempt {a+1} failed ({e}); waiting {wait}s", flush=True)
            time.sleep(wait)
    raise last

def mid_of(raw):
    try:
        m = email.message_from_bytes(raw)
        v = m.get("Message-ID") or m.get("Message-Id")
        return v.strip() if v else None
    except Exception:
        return None

def list_folders(c):
    out = []
    typ, data = c.list()
    if typ != "OK":
        return ["INBOX"]
    for line in data:
        if not line:
            continue
        s = line.decode(errors="replace")
        if '"' in s:
            name = s.split('"')[-2] if s.rstrip().endswith('"') else s.split('"')[-1].strip()
        else:
            name = s.split()[-1]
        out.append(name)
    return out

def collect_stalwart_mids(c):
    ids = set()
    for fld in list_folders(c):
        try:
            typ, _ = c.select('"%s"' % fld, readonly=True)
            if typ != "OK":
                continue
            typ, data = c.uid("search", None, "ALL")
            if typ != "OK" or not data or not data[0]:
                continue
            uids = data[0].split()
            for i in range(0, len(uids), 300):
                chunk = b",".join(uids[i:i+300])
                typ, fetched = c.uid("fetch", chunk, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
                if typ != "OK":
                    continue
                for part in fetched:
                    if isinstance(part, tuple) and part[1]:
                        m = mid_of(part[1])
                        if m:
                            ids.add(m)
        except Exception as e:
            print(f"  (folder {fld} skipped: {e})", flush=True)
    return ids

def gmail_connect():
    c = imaplib.IMAP4_SSL(*GMAIL)
    auth = "user=%s\x01auth=Bearer %s\x01\x01" % (USER, TOKEN)
    c.authenticate("XOAUTH2", lambda _x: auth.encode())
    return c

def main():
    # ONE Stalwart connection for both indexing and appending — a single login
    # keeps us under the aggressive per-account auth rate-limit.
    dst = stalwart_login()
    print("Indexing Stalwart (all folders) for Message-IDs...", flush=True)
    have = collect_stalwart_mids(dst)
    print(f"Stalwart already holds {len(have)} distinct Message-IDs", flush=True)

    g = gmail_connect()
    typ, d = g.select(SRC_MB, readonly=True)
    if typ != "OK":
        print(f"cannot select {SRC_MB}: {d}", flush=True); return
    typ, data = g.uid("search", None, "ALL")
    uids = data[0].split() if (typ == "OK" and data and data[0]) else []
    print(f"Gmail {SRC_MB} has {len(uids)} messages; finding missing ones...", flush=True)

    dst.select("INBOX")
    copied = skipped = failed = 0
    for n, uid in enumerate(uids, 1):
        typ, hf = g.uid("fetch", uid, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        mid = None
        if typ == "OK" and hf and isinstance(hf[0], tuple):
            mid = mid_of(hf[0][1])
        if mid and mid in have:
            skipped += 1
        else:
            typ, ff = g.uid("fetch", uid, "(FLAGS INTERNALDATE BODY.PEEK[])")
            if typ != "OK" or not ff or not isinstance(ff[0], tuple):
                failed += 1
            else:
                meta = ff[0][0]; raw = ff[0][1]
                if mid is None:
                    mid = mid_of(raw)
                if mid and mid in have:
                    skipped += 1
                else:
                    idate = None
                    try:
                        s = meta.decode(errors="replace")
                        if "INTERNALDATE" in s:
                            idate = '"' + s.split('INTERNALDATE "')[1].split('"')[0] + '"'
                    except Exception:
                        idate = None
                    try:
                        dst.append("INBOX", "(\\Seen)",
                                   idate or imaplib.Time2Internaldate(time.time()), raw)
                        copied += 1
                        if mid:
                            have.add(mid)
                    except Exception as e:
                        print(f"  append failed uid={uid.decode()}: {e}", flush=True)
                        failed += 1
        if n % 100 == 0:
            print(f"{n}/{len(uids)} copied={copied} skipped={skipped} failed={failed}", flush=True)
    print(f"DONE {SRC_MB}: copied={copied} skipped={skipped} failed={failed}", flush=True)
    g.logout(); dst.logout()

if __name__ == "__main__":
    main()
