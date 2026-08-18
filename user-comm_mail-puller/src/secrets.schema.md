# mail-puller — sops secrets schema

Plumbing lives in `build.json` / `sources.json`; only the secret **values** live
encrypted in `secrets.yaml` (sops/age). The Rust binary reads names from
`sources.json` (fields ending in `*_env`) and resolves each from the process
environment at runtime.

## Required keys

| Key                          | Consumer                                   | Description                                                              |
|------------------------------|--------------------------------------------|--------------------------------------------------------------------------|
| `GMAIL_CLIENT_ID`            | `sources[gmail-primary].oauth`              | Google Cloud OAuth 2.0 client ID (Desktop app type).                     |
| `GMAIL_CLIENT_SECRET`        | same                                        | Client secret (Desktop apps issue one; treat as secret).                 |
| `GMAIL_REFRESH_TOKEN`        | same                                        | Long-lived refresh token from a one-time browser authorize flow.         |
| `OUTLOOK_CLIENT_ID`          | `sources[live-primary].oauth`               | Azure AD app registration client ID ("Personal Microsoft accounts" audience). |
| `OUTLOOK_CLIENT_SECRET`      | same                                        | Azure client secret (or empty if public-client PKCE flow used).          |
| `OUTLOOK_REFRESH_TOKEN`      | same                                        | Refresh token with `offline_access IMAP.AccessAsUser.All` scope.         |
| `LOCAL_DELIVERY_USER`        | `delivery_targets.{maddy,stalwart}`        | Authenticated sender for local SMTP submission (e.g. `no-reply@diegonmarcos.com`). |
| `LOCAL_DELIVERY_PASSWORD`    | same                                        | Password for that sender on both Maddy + Stalwart.                       |

## Capturing refresh tokens (one-time)

Both Google and Microsoft require an interactive browser authorize step once.
Use any small helper that can perform an OAuth 2.0 code-flow with the right
scopes — `mutt_oauth2.py` ships presets for both providers.

```bash
# Gmail
python mutt_oauth2.py --authorize \
    --provider google \
    --client-id $GMAIL_CLIENT_ID \
    --client-secret $GMAIL_CLIENT_SECRET \
    --scope "https://mail.google.com/"

# Outlook/Live
python mutt_oauth2.py --authorize \
    --provider microsoft \
    --client-id $OUTLOOK_CLIENT_ID \
    --scope "offline_access IMAP.AccessAsUser.All SMTP.Send"
```

Each emits a `refresh_token` string. Drop it into sops and re-ship.

## Editing

```bash
cd ~/git/cloud-infra/a_solutions/aa-sui_mail-puller/src
sops secrets.yaml
# …add keys…
cd ..
./build.sh ship
```

Missing keys cause the affected source to log a warning and back off — other
sources keep working.
