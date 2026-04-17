# ╔══════════════════════════════════════════════════════════════════╗
# ║ Stalwart Mail Server — SHADOW MODE (nix-generated)             ║
# ║ Receives shadow copies from smtp-proxy, no outbound relay      ║
# ║ Secrets substituted at deploy time by init.sh from .secrets    ║
# ║ Source: ~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/     ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Server ──────────────────────────────────────────────────────
[server]
hostname = "@@MAIL_DOMAIN@@"
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
bind = ["0.0.0.0:@@PORT@@"]
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
domains = ["@@DOMAIN@@"]

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
directory = "'internal'"
require = [{if = "local_port != 2025", then = true}, {else = false}]

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

# ── Shadow mode: NO outbound relay ──────────────────────────────
# smtp-proxy delivers copies; Stalwart should never relay externally
# All outbound stays in queue (prevents duplicate sends)
[queue.outbound]
next-hop = "false"

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
