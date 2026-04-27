# cypht — sops secrets schema

Documents keys consumed at runtime by `init.sh`, `seed-accounts.sh`, and
the `cypht.env` runtime substitution. Encrypted values live in `secrets.yaml`
(sops/age).

| Key                      | Where used                                | What it is                                              |
|--------------------------|-------------------------------------------|---------------------------------------------------------|
| `CYPHT_DB_PASSWORD`      | `cypht.env` (DB_PASSWORD), `seed-accounts.sh` | PostgreSQL password for the `cypht` user                |
| `POSTGRES_PASSWORD`      | `cypht-postgres` env_file                 | Same value as `CYPHT_DB_PASSWORD` (postgres image needs this name) |
| `CYPHT_2FA_SECRET`       | `cypht.env` (APP_2FA_SECRET)              | 32-char random for Cypht's internal 2FA module          |
| `CYPHT_ADMIN_PASSWORD`   | `cypht.env` (ADMIN_PASSWORD)              | Cypht admin panel login (if enabled)                    |
| `ME_PASSWORD`            | `seed-accounts.sh` → primary account      | `me@diegonmarcos.com` IMAP password (Maddy)             |
| `ME_PASSWORD_STALWART`   | `seed-accounts.sh` → extras Stalwart entries | Stalwart IMAP/JMAP password for `me@`                  |
| `NOREPLY_PASSWORD`       | `seed-accounts.sh` → extras no-reply      | `no-reply@diegonmarcos.com` Maddy password              |
| `LIVE_APP_PASSWORD`      | `seed-accounts.sh` → extras Outlook       | Outlook app-password for `diegonmarcos@live.com`        |
| `GMAIL_APP_PASSWORD`     | `seed-accounts.sh` → extras Gmail         | Gmail app-password for `diegonmarcos1@gmail.com`        |

## Editing

```bash
cd ~/git/cloud/a_solutions/aa-sui_cypht/src
sops secrets.yaml
```

## Reuse with snappymail

The 5 user-account passwords (`ME_PASSWORD`, `ME_PASSWORD_STALWART`,
`NOREPLY_PASSWORD`, `LIVE_APP_PASSWORD`, `GMAIL_APP_PASSWORD`) are the SAME
secrets used by `aa-sui_snappymail`. Both webmails read the same backend
mail accounts. Keep these values in sync with snappymail's `secrets.yaml`.

## After editing

```bash
cd ~/git/cloud/a_solutions/aa-sui_cypht
./build.sh ship
```

The seeder is idempotent — re-ship overwrites `hm_user_settings` rows with
the current declarative list. Missing env vars cause that account to be
skipped silently (rest of the seed still applies).

## Initial bootstrap

`secrets.yaml` does not yet exist. To create it:

```bash
cd ~/git/cloud/a_solutions/aa-sui_cypht/src
# 1. Generate strong random values
openssl rand -base64 24    # → CYPHT_DB_PASSWORD
openssl rand -base64 24    # → CYPHT_2FA_SECRET (32+ chars)
openssl rand -base64 24    # → CYPHT_ADMIN_PASSWORD

# 2. Copy snappymail's account passwords (same backends)
sops -d ../../aa-sui_snappymail/src/secrets.yaml | grep -E '^(ME_PASSWORD|NOREPLY_PASSWORD|LIVE_APP_PASSWORD|GMAIL_APP_PASSWORD)'

# 3. Create + encrypt
sops --encrypt --age <YOUR_AGE_PUBKEY> --in-place secrets.yaml
```
