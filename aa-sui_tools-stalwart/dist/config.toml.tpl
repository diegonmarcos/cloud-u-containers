# ╔══════════════════════════════════════════════════════════════════╗
# ║ Stalwart Mail Server — declarative config (nix-generated)      ║
# ║ Secrets substituted at deploy time by init.sh from .secrets    ║
# ║ Source: ~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/     ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Server ──────────────────────────────────────────────────────
[server]
hostname = "mail.diegonmarcos.com"
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
bind = ["0.0.0.0:8443"]
protocol = "http"
tls.implicit = true

# ── TLS (ACME — Let's Encrypt via Cloudflare DNS-01) ────────────
[acme."letsencrypt"]
directory = "https://acme-v02.api.letsencrypt.org/directory"
challenge = "dns-01"
contact = "postmaster@diegonmarcos.com"
provider = "cloudflare"
secret = "${CF_DNS_API_TOKEN}"
domains = ["mail.diegonmarcos.com", "imap.diegonmarcos.com", "smtp.diegonmarcos.com"]
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
name = "admin@diegonmarcos.com"
secret = "${ADMIN_PASSWORD}"
email = ["admin@diegonmarcos.com", "postmaster@diegonmarcos.com"]

[[directory."static".principals]]
class = "individual"
name = "me@diegonmarcos.com"
secret = "${ME_PASSWORD}"
email = ["me@diegonmarcos.com"]

[[directory."static".principals]]
class = "individual"
name = "no-reply@diegonmarcos.com"
secret = "${NOREPLY_PASSWORD}"
email = ["no-reply@diegonmarcos.com", "noreply@diegonmarcos.com"]

# ── Authentication ──────────────────────────────────────────────
[authentication]
fallback-admin.user = "admin@diegonmarcos.com"
fallback-admin.secret = "${ADMIN_PASSWORD}"

[session.auth]
mechanisms = [{if = "is_tls", then = "[plain, login]"}, {else = false}]
directory = "'static'"
require = [{if = "local_port != 25", then = true}, {else = false}]

# ── Trusted networks (WG mesh + localhost) ──
# Security (rate-limiting, IP blocking) handled at cloud level (Caddy/firewalls)
[server.security]
trusted-networks = ["127.0.0.0/8", "10.0.0.0/24", "35.226.147.64/32"]
blocked-ip-addresses = false

# ── DKIM signing ────────────────────────────────────────────────
[signature."dkim"]
private-key = "%{file:/opt/stalwart-mail/dkim/diegonmarcos.com.dkim.key}%"
domain = "diegonmarcos.com"
selector = "dkim"
headers = ["From", "To", "Date", "Subject", "Message-ID"]
algorithm = "rsa-sha256"
canonicalization = "relaxed/relaxed"
set-body-length = false
report = true

# ── Outbound relay (OCI primary → AWS fallback) ─────────────────
[remote."oci-relay"]
address = "smtp.email.eu-marseille-1.oci.oraclecloud.com"
port = 587
protocol = "smtp"
tls.start-tls = true

[remote."oci-relay".auth]
username = "${OCI_RELAYUSER}"
password = "${OCI_RELAYPASSWORD}"

[remote."aws-relay"]
address = "email-smtp.us-east-1.amazonaws.com"
port = 587
protocol = "smtp"
tls.start-tls = true

[remote."aws-relay".auth]
username = "${AWS_RELAYUSER}"
password = "${AWS_RELAYPASSWORD}"

[queue.outbound]
next-hop = ["oci-relay", "aws-relay"]

# ── Spam filter (built-in) ──────────────────────────────────────
[spam.header]
is-spam = "X-Spam-Status: Yes"

# ── Message limits ──────────────────────────────────────────────
[session.data.limits]
size = 52428800

# ── Logging ─────────────────────────────────────────────────────
[tracing."stdout"]
type = "stdout"
level = "info"
enable = true
