# tools/others — auxiliary mail utilities (not MCP tools)

One-off operator scripts that don't belong in the steady-state MCP tool set.
Run them by hand; they are not wired into the MCP server.

## Mail architecture context

oci-mail runs **two stores**:

- **maddy** — inbound MX (WG-only :25) + outbound relay + its own imapsql store.
- **stalwart** — the JMAP/IMAP store clients read (:2443 / :2993).

Inbound: CF Email Routing → Worker `email-forwarder` → `/pub/mail/http-to-smtp`
→ maddy:25. maddy **dual-writes**: `deliver_to &local_mailboxes` (its own store)
**and** `deliver_to &stalwart_relay` (tcp://10.0.0.3:2025) — so new mail lands in
both stores atomically. The Worker also imports a copy into Google Workspace.

These scripts backfill mail that predates the dual-write.

## Scripts

### `gws_missing_backfill.py`
Copy ONLY the messages missing from Stalwart out of a Google Workspace mailbox
(`[Gmail]/All Mail` by default). Dedups by Message-ID across every Stalwart
folder → zero duplicates. Uses the domain-wide-delegation service account
(diego-cli@diegonmarcos-infra-prod) to mint a Gmail IMAP XOAUTH2 token — no
app password, no user consent. See the module docstring for the exact token
command and usage. Run from oci-mail (reaches both imap.gmail.com and the WG
Stalwart IMAP).

## Gotchas
- Stalwart has an aggressive per-account auth rate-limit (bans after a few
  auths in a short window, even successful ones). These scripts minimise
  logins (single Stalwart connection + backoff retry). Don't run other IMAP
  logins against the same account concurrently.
- Append target is Stalwart INBOX with original INTERNALDATE + `\Seen`.
