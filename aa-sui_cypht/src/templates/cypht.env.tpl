# Cypht main config — bind-mounted RO into the container at runtime.
# @VAR@ tokens are substituted at BUILD time by engine.nix from build.json.
# ${VAR} tokens are substituted at deploy time by configs/init.sh from .secrets.

# ── Database (PostgreSQL sidecar on loopback) ──────────────────────
# Upstream cypht expects DB_PASS (not DB_PASSWORD) and DB_CONNECTION_TYPE=host.
DB_DRIVER=pgsql
DB_CONNECTION_TYPE=host
DB_HOST=@POSTGRES_HOST@
DB_PORT=@POSTGRES_PORT@
DB_USER=@POSTGRES_USER@
DB_NAME=@POSTGRES_DB@
DB_PASS=${CYPHT_DB_PASSWORD}
DB_SOCKET=

# Postgres image expects POSTGRES_PASSWORD as well.
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=@POSTGRES_DB@
POSTGRES_USER=@POSTGRES_USER@

# ── Session + user storage (DB-backed) ─────────────────────────────
SESSION_TYPE=database
USER_CONFIG_TYPE=database

# ── Modules enabled at boot ────────────────────────────────────────
# Includes: jmap (vs Stalwart), feeds (RSS), calendar, carddav_contacts (Radicale),
# pgp, 2fa (TOTP), sievefilters, advanced_search.
CYPHT_MODULES=core,contacts,local_contacts,carddav_contacts,feeds,imap,jmap,smtp,account,idle_timer,calendar,themes,nux,history,saved_searches,advanced_search,highlights,profiles,inline_message,imap_folders,keyboard_shortcuts,tags,sievefilters,pgp,2fa

# ── 2FA (Cypht's internal TOTP — NOTE: Authelia is the outer gate) ─
APP_2FA_SECRET=${CYPHT_2FA_SECRET}

# ── Default IMAP server hint (for new accounts via UI) ─────────────
# Cypht's default IMAP server settings — Maddy via loopback (mail.${BASE_DOMAIN}
# resolves to 127.0.0.1 on oci-mail per /etc/hosts override; Maddy dual-binds
# 127.0.0.1 + 10.0.0.3 so loopback IMAPS works).
IMAP_AUTH_SERVER=@MAIL_DOMAIN@
IMAP_AUTH_PORT=993
IMAP_AUTH_TLS=1

# ── Default SMTP fallback ──────────────────────────────────────────
DEFAULT_SMTP_SERVER=@MAIL_DOMAIN@
DEFAULT_SMTP_PORT=465
DEFAULT_SMTP_TLS=1

# ── Listen port ────────────────────────────────────────────────────
# Override the upstream image's default :80 → match build.json ports.app.
# Cypht's bundled nginx binds this.
LISTEN_PORT=@CYPHT_PORT@

# ── Admin (if cypht admin module enabled) ──────────────────────────
ADMIN_PASSWORD=${CYPHT_ADMIN_PASSWORD}

# ── Stalwart endpoints (used by seed-accounts.sh for the second backend) ──
STALWART_HOST=@STALWART_DOMAIN@
STALWART_IMAP_PORT=@STALWART_IMAP_PORT@
STALWART_JMAP_PORT=@STALWART_JMAP_PORT@
STALWART_SMTP_PORT=@STALWART_SMTP_PORT@
