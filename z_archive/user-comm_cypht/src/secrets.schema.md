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
cd ~/git/cloud-infra/a_solutions/aa-sui_cypht/src
sops secrets.yaml
```

## Reuse with snappymail

The 5 user-account passwords (`ME_PASSWORD`, `ME_PASSWORD_STALWART`,
`NOREPLY_PASSWORD`, `LIVE_APP_PASSWORD`, `GMAIL_APP_PASSWORD`) are the SAME
secrets used by `aa-sui_snappymail`. Both webmails read the same backend
mail accounts. Keep these values in sync with snappymail's `secrets.yaml`.

## After editing

```bash
cd ~/git/cloud-infra/a_solutions/aa-sui_cypht
./build.sh ship
```

## Seeder scope (important — Cypht limitation)

Cypht stores IMAP/SMTP/JMAP server entries in `hm_user_settings.settings` as
a **BYTEA encrypted with the user's master password**. The seeder can NOT
inject server configs server-side without the master password's derived
encryption key.

What the seeder DOES:
- Initializes the PostgreSQL schema (`setup_database.php`)
- Creates the master user `me@diegonmarcos.com` with `ME_PASSWORD`

What you DO once after first ship:
- Log in to `https://webmail.diegonmarcos.com` with `me@diegonmarcos.com`
  and the value of `ME_PASSWORD`
- Open the Servers page; add the 5 backends from `seed-accounts.json`.
  Use the corresponding `*_PASSWORD` values from `.secrets` for each.

## Initial bootstrap

`secrets.yaml` does not yet exist. To create it:

```bash
cd ~/git/cloud-infra/a_solutions/aa-sui_cypht/src
# 1. Generate strong random values
openssl rand -base64 24    # → CYPHT_DB_PASSWORD
openssl rand -base64 24    # → CYPHT_2FA_SECRET (32+ chars)
openssl rand -base64 24    # → CYPHT_ADMIN_PASSWORD

# 2. Copy snappymail's account passwords (same backends)
sops -d ../../aa-sui_snappymail/src/secrets.yaml | grep -E '^(ME_PASSWORD|NOREPLY_PASSWORD|LIVE_APP_PASSWORD|GMAIL_APP_PASSWORD)'

# 3. Create + encrypt
sops --encrypt --age <YOUR_AGE_PUBKEY> --in-place secrets.yaml
```
