# google-personal-mcp

MCP server for **personal** Google accounts (gmail.com), parallel to `aa-sui_google-workspace-mcp`. Uses **App Passwords + IMAP/SMTP** instead of OAuth — permanent credentials, no Google verification, no CASA audit. Multi-account.

## Architecture

| | |
|---|---|
| Auth | Gmail App Password → IMAP `imap.gmail.com:993` + SMTP `smtp.gmail.com:465` |
| Transport | MCP Streamable HTTP at `https://mcp.diegonmarcos.com/g-personal/mcp` |
| Health | `https://mcp.diegonmarcos.com/g-personal/health` |
| Tools | `account_list`, `account_test`, `gmail_search`, `gmail_read`, `gmail_send`, `gmail_labels_list`, `gmail_label_apply`, `gmail_message_move`, `gmail_thread_messages` |
| Container | `ghcr.io/diegonmarcos/google-personal-mcp:latest` on `oci-apps:3106` |

Gmail-specific IMAP extensions exposed: `X-GM-RAW` (full Gmail search), `X-GM-THRID` (conversation threads), `X-GM-LABELS` (labels = mailboxes).

## Adding an account (declarative)

1. Generate an App Password at <https://myaccount.google.com/apppasswords> (16 chars).
2. Append to `build.json` `accounts[]`:
   ```json
   { "alias": "<short>", "email": "<addr>@gmail.com", "secret_env": "<SHORT>_APP_PASSWORD" }
   ```
3. Decrypt → edit → re-encrypt secrets:
   ```bash
   sops src/secrets.yaml         # opens $EDITOR with plaintext, re-encrypts on save
   ```
   Add the `<SHORT>_APP_PASSWORD: xxxxxxxxxxxxxxxx` line.
4. `./build.sh ship`

## Local test

```bash
src/code/tests/test-local.sh
```

Runs 6 checks: config schema, credential load, IMAP login, SMTP handshake, send-and-read self-roundtrip (auto-cleaned), health shape.

## Why not OAuth?

App Passwords on consumer Google accounts give permanent, free, no-verification access to the **mailbox** (IMAP/SMTP) — which covers the entire Gmail tool surface here. OAuth is required only for **Drive / Calendar / Contacts / Tasks**, which are not yet in scope. If/when added, a separate OAuth user-mode flow will be wired in (refresh tokens stored alongside App Passwords in `secrets.yaml`).
