terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_key = var.cloudflare_api_key
  email   = var.cloudflare_email
}

variable "cloudflare_api_key" {
  description = "Cloudflare Global API Key"
  type        = string
  sensitive   = true
}

variable "cloudflare_email" {
  description = "Cloudflare account email"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for diegonmarcos.com"
  type        = string
}

variable "dkim_mailu_public_key" {
  description = "Mailu DKIM public key (dkim._domainkey) - get from Mailu admin > Domains"
  type        = string
}

variable "dkim_cf_public_key" {
  description = "Cloudflare Email Routing DKIM key (cf2024-1._domainkey)"
  type        = string
}

variable "dkim_google_public_key" {
  description = "Google Workspace DKIM key (google._domainkey)"
  type        = string
}

variable "dkim_mail_public_key" {
  description = "Mailu legacy DKIM key (mail._domainkey)"
  type        = string
}

# =============================================================================
# DNS Records - Root & Wildcard
# All HTTP traffic routes through GCP Caddy Proxy (35.226.147.64)
# =============================================================================

resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
}

resource "cloudflare_record" "www" {
  zone_id = var.cloudflare_zone_id
  name    = "www"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
}

resource "cloudflare_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 1
  comment = "Wildcard catch-all → GCP Caddy"
}

# =============================================================================
# DNS Records - Service Subdomains (via GCP Caddy → WireGuard → target VM)
# =============================================================================

resource "cloudflare_record" "auth" {
  zone_id = var.cloudflare_zone_id
  name    = "auth"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Authelia 2FA"
}

resource "cloudflare_record" "analytics" {
  zone_id = var.cloudflare_zone_id
  name    = "analytics"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Matomo Analytics via Caddy → oci-analytics"
}

resource "cloudflare_record" "photos" {
  zone_id = var.cloudflare_zone_id
  name    = "photos"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "PhotoPrism via Caddy → oci-apps-1"
}

resource "cloudflare_record" "sync" {
  zone_id = var.cloudflare_zone_id
  name    = "sync"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Syncthing via Caddy → oci-mail"
}

resource "cloudflare_record" "cal" {
  zone_id = var.cloudflare_zone_id
  name    = "cal"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Radicale Calendar via Caddy → oci-mail"
}

resource "cloudflare_record" "ide" {
  zone_id = var.cloudflare_zone_id
  name    = "ide"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Code Server IDE via Caddy → oci-apps-1"
}

resource "cloudflare_record" "db" {
  zone_id = var.cloudflare_zone_id
  name    = "db"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "NocoDB via Caddy → oci-apps-1"
}

resource "cloudflare_record" "rss" {
  zone_id = var.cloudflare_zone_id
  name    = "rss"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Ntfy push notifications via Caddy on GCP"
}

resource "cloudflare_record" "proxy" {
  zone_id = var.cloudflare_zone_id
  name    = "proxy"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Caddy admin"
}

resource "cloudflare_record" "vault" {
  zone_id = var.cloudflare_zone_id
  name    = "vault"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Vaultwarden via Caddy on GCP"
}

resource "cloudflare_record" "drive_notes_affine" {
  zone_id = var.cloudflare_zone_id
  name    = "drive-notes-affine"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "AFFiNE workspace via Caddy → oci-apps-1"
}

resource "cloudflare_record" "suite" {
  zone_id = var.cloudflare_zone_id
  name    = "suite"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
}

resource "cloudflare_record" "linktree" {
  zone_id = var.cloudflare_zone_id
  name    = "linktree"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
}

resource "cloudflare_record" "cloud" {
  zone_id = var.cloudflare_zone_id
  name    = "cloud"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
}

resource "cloudflare_record" "nexus" {
  zone_id = var.cloudflare_zone_id
  name    = "nexus"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
}

resource "cloudflare_record" "api" {
  zone_id = var.cloudflare_zone_id
  name    = "api"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Flask + Rust API via Caddy on GCP"
}

# =============================================================================
# DNS Records - External services
# =============================================================================

resource "cloudflare_record" "chat_google" {
  zone_id = var.cloudflare_zone_id
  name    = "chat"
  type    = "CNAME"
  content = "ghs.googlehosted.com"
  proxied = true
  ttl     = 1
  comment = "Google Chat / Workspace"
}

# =============================================================================
# DNS Records - Mail (direct to oci-mail - 130.110.251.193)
# Cannot proxy SMTP ports through Cloudflare
# =============================================================================

resource "cloudflare_record" "mail" {
  zone_id = var.cloudflare_zone_id
  name    = "mail"
  type    = "A"
  content = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Mailu webmail via Caddy → oci-mail"
}

resource "cloudflare_record" "smtp" {
  zone_id = var.cloudflare_zone_id
  name    = "smtp"
  type    = "A"
  content = "130.110.251.193"
  proxied = false
  ttl     = 300
  comment = "SMTP direct to oci-mail - used in SPF + outbound SMTP client config"
}

resource "cloudflare_record" "imap" {
  zone_id = var.cloudflare_zone_id
  name    = "imap"
  type    = "A"
  content = "130.110.251.193"
  proxied = false
  ttl     = 300
  comment = "IMAP direct to oci-mail"
}

resource "cloudflare_record" "smtp_proxy_tunnel" {
  zone_id = var.cloudflare_zone_id
  name    = "smtp-proxy"
  type    = "CNAME"
  content = "90b644ed-1339-4fbe-a467-687012aa84ae.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare Tunnel → smtp-proxy on oci-mail (alternative to direct port 8080)"
}

# =============================================================================
# MX Records - Managed by Cloudflare Email Routing (NOT Terraform)
#
# CF Email Routing auto-manages: route1/2/3.mx.cloudflare.net
# These records CANNOT be modified/deleted while Email Routing is enabled.
#
# EMAIL FLOW:
#   INBOUND:  Sender → CF MX (route1/2/3.mx.cloudflare.net)
#             → Email Routing Worker "email-forwarder"
#             → smtp-proxy (oci-mail:8080) → Mailu front:25
#   OUTBOUND: Mailu → OCI Email Delivery relay (smtp.email.eu-marseille-1.oci.oraclecloud.com:587)
#
# Email Routing rules are in CF Dashboard (not Terraform):
#   me@diegonmarcos.com → Worker "email-forwarder"
# =============================================================================

# =============================================================================
# TXT Records - Email Authentication
# =============================================================================

# SPF - ONE record only (RFC 7208: multiple SPF records = permerror)
# - include:_spf.mx.cloudflare.net   → authorizes CF Email Routing forwarding
# - include:eu.rp.oracleemaildelivery.com → authorizes OCI Email Delivery relay (eu-marseille-1)
# - a:smtp.diegonmarcos.com          → authorizes direct Mailu outbound (backup)
resource "cloudflare_record" "spf" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "TXT"
  content = "v=spf1 include:_spf.mx.cloudflare.net include:eu.rp.oracleemaildelivery.com a:smtp.diegonmarcos.com ~all"
  ttl     = 300
  comment = "SPF: CF Email Routing + OCI relay + Mailu. ONE record only."
}

# DMARC - reject emails failing SPF+DKIM (domain spoofing protection)
resource "cloudflare_record" "dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc"
  type    = "TXT"
  content = "v=DMARC1; p=reject; rua=mailto:postmaster@diegonmarcos.com"
  ttl     = 300
  comment = "DMARC: reject spoofed emails"
}

# DKIM - Mailu (primary selector used by Mailu rspamd to sign outbound mail)
resource "cloudflare_record" "dkim_mailu" {
  zone_id = var.cloudflare_zone_id
  name    = "dkim._domainkey"
  type    = "TXT"
  content = var.dkim_mailu_public_key
  ttl     = 300
  comment = "Mailu DKIM - selector: dkim"
}

# DKIM - Cloudflare Email Routing (auto-managed by CF for inbound forwarding)
resource "cloudflare_record" "dkim_cloudflare" {
  zone_id = var.cloudflare_zone_id
  name    = "cf2024-1._domainkey"
  type    = "TXT"
  content = var.dkim_cf_public_key
  ttl     = 1
  comment = "Cloudflare Email Routing DKIM (auto-managed by CF)"
}

# DKIM - Google Workspace (legacy)
resource "cloudflare_record" "dkim_google" {
  zone_id = var.cloudflare_zone_id
  name    = "google._domainkey"
  type    = "TXT"
  content = var.dkim_google_public_key
  ttl     = 1
  comment = "Google Workspace DKIM (legacy)"
}

# DKIM - Mailu legacy selector
resource "cloudflare_record" "dkim_mail" {
  zone_id = var.cloudflare_zone_id
  name    = "mail._domainkey"
  type    = "TXT"
  content = var.dkim_mail_public_key
  ttl     = 300
  comment = "Mailu legacy DKIM selector"
}

# =============================================================================
# DNS Records - Security
# =============================================================================

# CAA - Only Let's Encrypt may issue TLS certificates for this domain
resource "cloudflare_record" "caa_letsencrypt" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "CAA"
  data {
    flags = "0"
    tag   = "issue"
    value = "letsencrypt.org"
  }
  ttl     = 300
  comment = "CAA: restrict cert issuance to Let's Encrypt only"
}

# =============================================================================
# SSL/TLS Settings
# =============================================================================

resource "cloudflare_zone_settings_override" "ssl_settings" {
  zone_id = var.cloudflare_zone_id

  settings {
    ssl                      = "full"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    automatic_https_rewrites = "on"
    opportunistic_encryption = "on"
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "email_architecture" {
  value = "CF Email Routing (MX) → Worker email-forwarder → smtp-proxy (oci-mail:8080) → Mailu front:25"
}
