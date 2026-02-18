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

# =============================================================================
# DNS Records - All HTTP traffic routes through GCP Caddy Proxy
# =============================================================================

# Root domain -> GCP Caddy
resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300  # Auto when proxied
}

# www -> GCP Caddy
resource "cloudflare_record" "www" {
  zone_id = var.cloudflare_zone_id
  name    = "www"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
}

# =============================================================================
# Service Subdomains - All proxied through GCP Caddy
# =============================================================================

# Authentication (Authelia)
resource "cloudflare_record" "auth" {
  zone_id = var.cloudflare_zone_id
  name    = "auth"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Authelia 2FA - direct on GCP"
}

# Analytics (Matomo) - via Caddy to oci-analytics
resource "cloudflare_record" "analytics" {
  zone_id = var.cloudflare_zone_id
  name    = "analytics"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Matomo Analytics - via Caddy to oci-analytics"
}

# PhotoPrism - via Caddy to oci-flex-1
resource "cloudflare_record" "photos" {
  zone_id = var.cloudflare_zone_id
  name    = "photos"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "PhotoPrism - via Caddy to oci-flex-1"
}

# Syncthing - via Caddy to oci-mail
resource "cloudflare_record" "sync" {
  zone_id = var.cloudflare_zone_id
  name    = "sync"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Syncthing - via Caddy to oci-mail"
}

# Calendar (Radicale) - via Caddy to oci-flex-1
resource "cloudflare_record" "cal" {
  zone_id = var.cloudflare_zone_id
  name    = "cal"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Radicale Calendar - via Caddy to oci-flex-1"
}

# Code Server IDE - via Caddy to oci-flex-1
resource "cloudflare_record" "ide" {
  zone_id = var.cloudflare_zone_id
  name    = "ide"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Code Server IDE - via Caddy to oci-flex-1"
}

# NocoDB - via Caddy to oci-flex-1
resource "cloudflare_record" "db" {
  zone_id = var.cloudflare_zone_id
  name    = "db"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "NocoDB - via Caddy to oci-flex-1"
}

# Ntfy Push Notifications - via Caddy on GCP
resource "cloudflare_record" "rss" {
  zone_id = var.cloudflare_zone_id
  name    = "rss"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Ntfy push notifications - via Caddy on GCP"
}

# Caddy Admin Proxy
resource "cloudflare_record" "proxy" {
  zone_id = var.cloudflare_zone_id
  name    = "proxy"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Caddy admin UI"
}

# Vaultwarden - via Caddy on GCP
resource "cloudflare_record" "vault" {
  zone_id = var.cloudflare_zone_id
  name    = "vault"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Vaultwarden password manager - via Caddy on GCP"
}

# Grist Sheets - via Caddy to oci-flex-1
resource "cloudflare_record" "sheets" {
  zone_id = var.cloudflare_zone_id
  name    = "sheets"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Grist Sheets - via Caddy to oci-flex-1"
}

# AFFiNE Drive - via Caddy to oci-flex-1
resource "cloudflare_record" "drive_notes_affine" {
  zone_id = var.cloudflare_zone_id
  name    = "drive-notes-affine"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "AFFiNE workspace - via Caddy to oci-flex-1"
}

# Suite - static site via Caddy to GitHub Pages
resource "cloudflare_record" "suite" {
  zone_id = var.cloudflare_zone_id
  name    = "suite"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Suite landing - via Caddy to GitHub Pages"
}

# =============================================================================
# Front-end Subdomains - Static sites via Caddy to GitHub Pages
# =============================================================================

# Linktree - via Caddy to GitHub Pages
resource "cloudflare_record" "linktree" {
  zone_id = var.cloudflare_zone_id
  name    = "linktree"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Linktree - via Caddy to GitHub Pages"
}

# Cloud dashboard - via Caddy to GitHub Pages
resource "cloudflare_record" "cloud" {
  zone_id = var.cloudflare_zone_id
  name    = "cloud"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Cloud dashboard - via Caddy to GitHub Pages"
}

# Nexus - via Caddy to GitHub Pages
resource "cloudflare_record" "nexus" {
  zone_id = var.cloudflare_zone_id
  name    = "nexus"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Nexus - via Caddy to GitHub Pages"
}

# API - Flask + Rust on GCP
resource "cloudflare_record" "api" {
  zone_id = var.cloudflare_zone_id
  name    = "api"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Flask + Rust API - via Caddy on GCP"
}

# =============================================================================
# Mail Records - Direct to OCI Micro 1 (not proxied for SMTP)
# =============================================================================

# Mail webmail interface - via Caddy to oci-mail
resource "cloudflare_record" "mail" {
  zone_id = var.cloudflare_zone_id
  name    = "mail"
  type    = "A"
  content   = "35.226.147.64"
  proxied = false
  ttl     = 300
  comment = "Mailu webmail - via Caddy to oci-mail"
}

# SMTP direct (cannot be proxied)
resource "cloudflare_record" "smtp" {
  zone_id = var.cloudflare_zone_id
  name    = "smtp"
  type    = "A"
  content   = "130.110.251.193"
  proxied = false
  ttl     = 300
  comment = "SMTP direct - cannot proxy email traffic"
}

# MX Record
resource "cloudflare_record" "mx" {
  zone_id  = var.cloudflare_zone_id
  name     = "@"
  type     = "MX"
  content    = "smtp.diegonmarcos.com"
  priority = 10
  ttl      = 300
}

# SPF Record
resource "cloudflare_record" "spf" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "TXT"
  content   = "v=spf1 mx a:smtp.diegonmarcos.com -all"
  ttl     = 300
}

# DKIM Record (placeholder - actual key from Mailu)
resource "cloudflare_record" "dkim" {
  zone_id = var.cloudflare_zone_id
  name    = "dkim._domainkey"
  type    = "TXT"
  content   = var.dkim_public_key
  ttl     = 300
}

variable "dkim_public_key" {
  description = "DKIM public key from Mailu"
  type        = string
  default     = "v=DKIM1; k=rsa; p=CHANGE_ME_DKIM_KEY"
}

# DMARC Record
resource "cloudflare_record" "dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc"
  type    = "TXT"
  content   = "v=DMARC1; p=reject; rua=mailto:postmaster@diegonmarcos.com"
  ttl     = 300
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
# Page Rules
# =============================================================================

resource "cloudflare_page_rule" "cache_static" {
  zone_id  = var.cloudflare_zone_id
  target   = "*.diegonmarcos.com/*"
  priority = 1

  actions {
    cache_level = "cache_everything"
    edge_cache_ttl = 86400
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "nameservers" {
  value = ["burt.ns.cloudflare.com", "phoenix.ns.cloudflare.com"]
}

output "dns_records_count" {
  value = "24 DNS records configured"
}
