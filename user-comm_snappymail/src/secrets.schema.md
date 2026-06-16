# snappymail — sops secrets schema

This file documents the keys consumed at runtime by `init.sh`,
`seed-accounts.php`, and the domain `.ini` template substitution.
The actual values live encrypted in `secrets.yaml` (sops/age).

| Key                        | Where used                           | What it is                                |
|----------------------------|--------------------------------------|-------------------------------------------|
| `SNAPPYMAIL_ADMIN_PASSWORD`| `application.ini` (admin panel)       | Admin UI login                            |
| `ME_PASSWORD`              | `seed-accounts.php` → CryptKey seed   | Primary user's IMAP password (same as Maddy `ME_PASSWORD`) |
| `ME_PASSWORD_STALWART`     | `seed-accounts.php` → extras[0].pass  | Stalwart IMAP password for `me@`          |
| `NOREPLY_PASSWORD`         | `seed-accounts.php` → extras[1].pass  | `no-reply@diegonmarcos.com` Maddy pw      |
| `LIVE_APP_PASSWORD`        | `seed-accounts.php` → extras[2].pass  | Outlook app-password for `diegonmarcos@live.com` |
| `GMAIL_APP_PASSWORD`       | `seed-accounts.php` → extras[3].pass  | Gmail app-password for `diegonmarcos1@gmail.com` |
| `MAIL_STALWART_HOST`       | `jmap.diegonmarcos.com.ini` (envsubst) | Override if Stalwart hostname differs. Default: `jmap.diegonmarcos.com` |
| `MAIL_STALWART_IMAP_PORT`  | same                                  | Default: `2993` |
| `MAIL_STALWART_SMTP_PORT`  | same                                  | Default: `2465` |

## Editing

```bash
cd ~/git/cloud/a_solutions/aa-sui_snappymail/src
sops secrets.yaml
```

After adding / changing keys, re-ship:

```bash
cd ~/git/cloud/a_solutions/aa-sui_snappymail
./build.sh ship
```

The seeder is idempotent — re-ship overwrites the `accounts` file for the
primary user with the current declarative list. Missing envs cause that
specific extra to be skipped silently (rest of the seed still applies).
