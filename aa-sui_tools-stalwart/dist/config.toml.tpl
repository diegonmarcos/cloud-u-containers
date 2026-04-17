# ╔══════════════════════════════════════════════════════════════════╗
# ║ Stalwart Mail Server — SHADOW MODE (nix-generated)             ║
# ║ Receives shadow copies from smtp-proxy, no outbound relay      ║
# ║ Secrets substituted at deploy time by init.sh from .secrets    ║
# ║ Source: ~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/     ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Server ──────────────────────────────────────────────────────
[server]
hostname = "mail-stalwart.diegonmarcos.com"
max-connections = 512

# ── Listeners (offset ports — parallel with Maddy) ─────────────
[server.listener."smtp"]
bind = ["0.0.0.0:2025"]
protocol = "smtp"

[server.listener."submissions"]
bind = ["0.0.0.0:2465"]
protocol = "smtp"
tls.implicit = true

[server.listener."submission"]
bind = ["0.0.0.0:2587"]
protocol = "smtp"

[server.listener."imaptls"]
bind = ["0.0.0.0:2993"]
protocol = "imap"
tls.implicit = true

[server.listener."sieve"]
bind = ["0.0.0.0:6190"]
protocol = "managesieve"

[server.listener."https"]
bind = ["0.0.0.0:2443"]
protocol = "http"
tls.implicit = true

# ── TLS (shared Caddy wildcard cert — *.diegonmarcos.com) ──────
[certificate."default"]
default = true
cert = "%{file:/opt/stalwart-mail/tls/fullchain.pem}%"
private-key = "%{file:/opt/stalwart-mail/tls/privkey.pem}%"

# ── SMTP session — accept mail for local domains ───────────────
[session.rcpt]
directory = "'internal'"
# Port 2025: inbound only (no relay). Ports 2465/2587: relay allowed (auth required).
relay = [{if = "local_port == 2025", then = "false"}, {else = "true"}]

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
directory = "internal"

# ── Internal directory (RocksDB-backed — used for delivery routing) ───
[directory."internal"]
type = "internal"
store = "rocksdb"

# ── Directory (static accounts — bootstraps users from config) ───────
[directory."static"]
type = "memory"
domains = ["diegonmarcos.com"]

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
directory = "'internal'"
require = [{if = "local_port != 2025", then = true}, {else = false}]

# ── OAuth (v0.13 webadmin requires this) ────────────────────────
[oauth]
key = "${ADMIN_PASSWORD}"

# ── Security DISABLED — handled at cloud level (Caddy + Authelia + firewalls) ──
# Stalwart bug: allowed-ip-addresses + fail2ban block WG IPs despite being in trusted-networks
# No server.security section = accept all connections (firewalls do the filtering)

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

# ── Shadow mode: local delivery only, no external relay ─────────
# "local" = deliver to local mailbox without MX lookup
# Non-local domains get no relay → messages expire and are discarded
[queue.outbound]
next-hop = "'local'"

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
