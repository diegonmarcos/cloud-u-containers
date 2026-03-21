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

# ── TLS (ACME — Let's Encrypt) ─────────────────────────────────
[acme."letsencrypt"]
directory = "https://acme-v02.api.letsencrypt.org/directory"
contact = ["mailto:me@diegonmarcos.com"]
domains = ["mail.diegonmarcos.com"]
challenge = "tls-alpn-01"

[certificate."default"]
cert = "%{file:/opt/stalwart/data/acme/letsencrypt/cert.pem}%"
private-key = "%{file:/opt/stalwart/data/acme/letsencrypt/key.pem}%"

# ── Storage (RocksDB + filesystem) ──────────────────────────────
[store."rocksdb"]
type = "rocksdb"
path = "/opt/stalwart/data/db"

[store."blob"]
type = "fs"
path = "/opt/stalwart/data/blobs"

[storage]
data = "rocksdb"
blob = "blob"
fts = "rocksdb"
lookup = "rocksdb"
directory = "internal"

# ── Directory (internal accounts) ───────────────────────────────
[directory."internal"]
type = "internal"
store = "rocksdb"

# ── Authentication ──────────────────────────────────────────────
[authentication]
fallback-admin.user = "admin"
fallback-admin.secret = "${ADMIN_PASSWORD}"

[session.auth]
mechanisms = ["PLAIN", "LOGIN"]
directory = "internal"

# ── DKIM signing ────────────────────────────────────────────────
[signature."dkim"]
private-key = "%{file:/opt/stalwart/dkim/diegonmarcos.com.dkim.key}%"
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
