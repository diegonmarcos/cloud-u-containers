# ╔══════════════════════════════════════════════════════════════════╗
# ║ Stalwart Mail Server — declarative config (nix-generated)      ║
# ║ Secrets substituted at deploy time by init.sh from .secrets    ║
# ║ Source: ~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/     ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Server ──────────────────────────────────────────────────────
[server]
hostname = "@@MAIL_DOMAIN@@"
max-connections = 512

# ── Listeners ───────────────────────────────────────────────────
[server.listener."smtp"]
bind = ["0.0.0.0:25"]
protocol = "smtp"

[server.listener."submissions"]
bind = ["0.0.0.0:465"]
protocol = "smtp"
tls.implicit = true

[server.listener."submission"]
bind = ["0.0.0.0:587"]
protocol = "smtp"

[server.listener."imaptls"]
bind = ["0.0.0.0:993"]
protocol = "imap"
tls.implicit = true

[server.listener."sieve"]
bind = ["0.0.0.0:4190"]
protocol = "managesieve"

[server.listener."https"]
bind = ["0.0.0.0:@@PORT@@"]
protocol = "http"
tls.implicit = true

# ── TLS (ACME — Let's Encrypt via Cloudflare DNS-01) ────────────
[acme."letsencrypt"]
directory = "https://acme-v02.api.letsencrypt.org/directory"
challenge = "dns-01"
contact = "postmaster@@@DOMAIN@@"
provider = "cloudflare"
secret = "${CF_DNS_API_TOKEN}"
domains = ["@@MAIL_DOMAIN@@", "imap.@@DOMAIN@@", "smtp.@@DOMAIN@@"]
renew-before = "30d"

# ── Certificate (link ACME to listeners) ───────────────────────
[certificate."default"]
default = true
acme = "letsencrypt"

# ── SMTP session — accept mail for local domains ───────────────
[session.rcpt]
directory = "'static'"

# ── Storage (RocksDB + filesystem) ──────────────────────────────
[store."rocksdb"]
type = "rocksdb"
path = "/opt/stalwart-mail/data/db"

[store."blob"]
type = "fs"
path = "/opt/stalwart-mail/data/blobs"

[storage]
data = "rocksdb"
blob = "blob"
fts = "rocksdb"
lookup = "rocksdb"
directory = "static"

# ── Directory (static accounts — fully declarative) ─────────────
# Domains auto-derived from email addresses in principals
[directory."static"]
type = "memory"

[[directory."static".principals]]
class = "admin"
name = "admin@@@DOMAIN@@"
secret = "${ADMIN_PASSWORD}"
email = ["admin@@@DOMAIN@@", "postmaster@@@DOMAIN@@"]

[[directory."static".principals]]
class = "individual"
name = "me@@@DOMAIN@@"
secret = "${ME_PASSWORD}"
email = ["me@@@DOMAIN@@"]

[[directory."static".principals]]
class = "individual"
name = "no-reply@@@DOMAIN@@"
secret = "${NOREPLY_PASSWORD}"
email = ["no-reply@@@DOMAIN@@", "noreply@@@DOMAIN@@"]

# ── Authentication ──────────────────────────────────────────────
[authentication]
fallback-admin.user = "admin@@@DOMAIN@@"
fallback-admin.secret = "${ADMIN_PASSWORD}"

[session.auth]
mechanisms = [{if = "is_tls", then = "[plain, login]"}, {else = false}]
directory = "'static'"
require = [{if = "local_port != 25", then = true}, {else = false}]

# ── Trusted networks (WG mesh + localhost) ──
# Security (rate-limiting, IP blocking) handled at cloud level (Caddy/firewalls)
[server.security]
trusted-networks = ["127.0.0.0/8", "10.0.0.0/24", "35.226.147.64/32"]
allowed-ip-addresses = ["127.0.0.0/8", "10.0.0.0/24", "35.226.147.64/32"]

[authentication.fail2ban]
rate = "100/60s"

# ── DKIM signing ────────────────────────────────────────────────
[signature."dkim"]
private-key = "%{file:/opt/stalwart-mail/dkim/@@DOMAIN@@.dkim.key}%"
domain = "@@DOMAIN@@"
selector = "dkim"
headers = ["From", "To", "Date", "Subject", "Message-ID"]
algorithm = "rsa-sha256"
canonicalization = "relaxed/relaxed"
set-body-length = false
report = true

# ── Outbound relay (OCI primary → AWS fallback) ─────────────────
[remote."oci-relay"]
address = "@@OCI_RELAY_HOST@@"
port = @@OCI_RELAY_PORT@@
protocol = "smtp"
tls.start-tls = true

[remote."oci-relay".auth]
username = "${OCI_RELAYUSER}"
password = "${OCI_RELAYPASSWORD}"

[remote."aws-relay"]
address = "@@AWS_RELAY_HOST@@"
port = @@AWS_RELAY_PORT@@
protocol = "smtp"
tls.start-tls = true

[remote."aws-relay".auth]
username = "${AWS_RELAYUSER}"
password = "${AWS_RELAYPASSWORD}"

[queue.outbound]
next-hop = [{if = "is_local_domain('static', rcpt_domain)", then = "false"}, {else = "'oci-relay'"}]

# ── Spam filter (built-in) ──────────────────────────────────────
[spam.header]
is-spam = "X-Spam-Status: Yes"

# ── Message limits ──────────────────────────────────────────────
[session.data.limits]
size = @@MESSAGE_SIZE_LIMIT@@

# ── Logging ─────────────────────────────────────────────────────
[tracing."stdout"]
type = "stdout"
level = "info"
enable = true
