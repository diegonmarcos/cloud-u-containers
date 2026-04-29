# Stalwart v0.13 — minimal config (shadow mode, offset ports)
# Matches auto-generated format. Admin panel manages everything else.

[server]
hostname = "@DOMAIN@"
url = "https://@DOMAIN@"

[server.listener.smtp]
bind = "[::]:2025"
protocol = "smtp"

[server.listener.submission]
bind = "[::]:2587"
protocol = "smtp"

[server.listener.submissions]
bind = "[::]:2465"
protocol = "smtp"
tls.implicit = true

[server.listener.imaptls]
bind = "[::]:2993"
protocol = "imap"
tls.implicit = true

[server.listener.sieve]
bind = "[::]:6190"
protocol = "managesieve"

[server.listener.https]
protocol = "http"
bind = "[::]:@APP_PORT@"
tls.implicit = true

[server.listener.http]
protocol = "http"
bind = "[::]:8080"

[storage]
data = "rocksdb"
fts = "rocksdb"
blob = "rocksdb"
lookup = "rocksdb"
directory = "internal"

[store.rocksdb]
type = "rocksdb"
path = "/opt/stalwart-mail/data"
compression = "lz4"

[directory.internal]
type = "internal"
store = "rocksdb"

[certificate.default]
default = true
cert = "%{file:/opt/stalwart-mail/tls/fullchain.pem}%"
private-key = "%{file:/opt/stalwart-mail/tls/privkey.pem}%"

[authentication.fallback-admin]
user = "admin"
secret = "@ADMIN_HASH@"

# ── Inbound SMTP (port 2025): no auth required (shadow delivery from smtp-proxy) ──
[session.auth]
require = [{if = "local_port != 2025", then = true}, {else = false}]

# ── Security: WG mesh is fully trusted ───────────────────────────────
# All Stalwart listeners bind WG-only (or to gcp-proxy / smtp-proxy via WG),
# so IP-based fail2ban / auto-blocking is redundant and actively harmful
# (it bans the puller after a single auth misconfig retry storm).
#
# 1) Disable fail2ban by setting thresholds to never-trigger values.
[auth.fail2ban]
authentication = "0/0"
invalid-rcpt   = "0/0"
loiter         = "0/0"

# 2) Allow-list the WG /24 so any IP-based block check short-circuits
#    in security.rs::is_ip_allowed(). Stalwart's set_values() reads the key
#    suffix as the IP/CIDR; the value is unused.
server.allowed-ip = ["10.0.0.0/24"]

# ── STARTTLS on submission (port 2587) ───────────────────────────────
# Without this the listener accepts plaintext but never advertises
# STARTTLS, so the mail-puller can't upgrade the connection. We bind on
# WG only — the cert is wildcard *.diegonmarcos.com via Caddy renewal.
[server.listener.submission.tls]
implicit = false

[tracer.log]
type = "stdout"
level = "info"
enable = true
