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

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
  default     = "e5cb0a0c6f448e54f217de484259f0ae"
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

# AWS SES verification + DKIM tokens (from terraform output of b_infra/vps_aws/)
variable "ses_verification_token" {
  description = "SES domain verification token (_amazonses TXT record)"
  type        = string
  default     = ""
}

variable "ses_dkim_token_1" {
  description = "SES DKIM token 1 of 3"
  type        = string
  default     = ""
}

variable "ses_dkim_token_2" {
  description = "SES DKIM token 2 of 3"
  type        = string
  default     = ""
}

variable "ses_dkim_token_3" {
  description = "SES DKIM token 3 of 3"
  type        = string
  default     = ""
}

# =============================================================================
# DNS Records - Root & Wildcard
# All HTTP traffic routes through GCP Caddy Proxy (35.226.147.64)
# =============================================================================

resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "diegonmarcos.com"
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
# DNS Records - Service Subdomains
# All subdomains resolved by wildcard → gcp-proxy (Caddy is routing source of truth)
# Individual A records REMOVED — wildcard catches everything.
# Caddy Caddyfile defines which subdomain routes to which WG backend.
# =============================================================================

resource "cloudflare_record" "smtp_proxy_tunnel" {
  zone_id = var.cloudflare_zone_id
  name    = "smtp-proxy"
  type    = "CNAME"
  content = "90b644ed-1339-4fbe-a467-687012aa84ae.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare Tunnel → smtp-proxy on oci-mail"
}

# Tunnel ingress config — routes smtp-proxy.diegonmarcos.com → localhost:8080
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "smtp_proxy" {
  account_id = var.cloudflare_account_id
  tunnel_id  = "90b644ed-1339-4fbe-a467-687012aa84ae"

  config {
    ingress_rule {
      hostname = "smtp-proxy.diegonmarcos.com"
      service  = "http://localhost:8080"
    }
    # Catch-all (required by Cloudflare)
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# =============================================================================
# Email Routing - Declarative (previously Dashboard-only)
#
# MX records (route1/2/3.mx.cloudflare.net) are auto-managed by CF Email Routing.
#
# EMAIL FLOW:
#   INBOUND:  Sender → CF MX → Email Routing Rule → Worker "email-forwarder"
#             → smtp-proxy (oci-mail:8080) → Mailu front:25
#   OUTBOUND: Mailu → AWS SES relay (email-smtp.us-east-1.amazonaws.com:587)
# =============================================================================

# Verified destination for backup forwarding
resource "cloudflare_email_routing_address" "backup" {
  account_id = var.cloudflare_account_id
  email      = "diegonmarcos@live.com"
}

# Route me@diegonmarcos.com → Worker "email-forwarder"
resource "cloudflare_email_routing_rule" "me_to_worker" {
  zone_id  = var.cloudflare_zone_id
  name     = "Forward to Worker (Gmail + Stalwart)"
  enabled  = true
  priority = 0

  matcher {
    type  = "literal"
    field = "to"
    value = "me@diegonmarcos.com"
  }

  action {
    type  = "worker"
    value = ["email-forwarder"]
  }
}

# =============================================================================
# TXT Records - Email Authentication
# =============================================================================

# SPF - ONE record only (RFC 7208: multiple SPF records = permerror)
# - include:_spf.mx.cloudflare.net          → authorizes CF Email Routing forwarding
# - include:amazonses.com                   → authorizes AWS SES relay (primary)
# - include:eu.rp.oracleemaildelivery.com   → authorizes OCI Email Delivery (fallback)
resource "cloudflare_record" "spf" {
  zone_id = var.cloudflare_zone_id
  name    = "diegonmarcos.com"
  type    = "TXT"
  content = "v=spf1 include:_spf.mx.cloudflare.net include:amazonses.com include:eu.rp.oracleemaildelivery.com ~all"
  ttl     = 300
  comment = "SPF: CF Email Routing + AWS SES (primary) + OCI relay (fallback). Outbound via relays only."
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
# TXT/CNAME Records - AWS SES (domain verification + DKIM + MAIL FROM)
# Tokens from: b_infra/vps_aws/ terraform output
# =============================================================================

# SES domain verification
resource "cloudflare_record" "ses_verification" {
  zone_id = var.cloudflare_zone_id
  name    = "_amazonses"
  type    = "TXT"
  content = var.ses_verification_token
  ttl     = 300
  comment = "AWS SES domain verification"
}

# SES Easy DKIM (3 CNAME records)
resource "cloudflare_record" "ses_dkim_1" {
  zone_id = var.cloudflare_zone_id
  name    = "${var.ses_dkim_token_1}._domainkey"
  type    = "CNAME"
  content = "${var.ses_dkim_token_1}.dkim.amazonses.com"
  ttl     = 300
  comment = "AWS SES DKIM 1/3"
}

resource "cloudflare_record" "ses_dkim_2" {
  zone_id = var.cloudflare_zone_id
  name    = "${var.ses_dkim_token_2}._domainkey"
  type    = "CNAME"
  content = "${var.ses_dkim_token_2}.dkim.amazonses.com"
  ttl     = 300
  comment = "AWS SES DKIM 2/3"
}

resource "cloudflare_record" "ses_dkim_3" {
  zone_id = var.cloudflare_zone_id
  name    = "${var.ses_dkim_token_3}._domainkey"
  type    = "CNAME"
  content = "${var.ses_dkim_token_3}.dkim.amazonses.com"
  ttl     = 300
  comment = "AWS SES DKIM 3/3"
}

# Custom MAIL FROM — MX + SPF for mail.diegonmarcos.com (SES bounce subdomain)
resource "cloudflare_record" "ses_mail_from_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = "mail"
  type     = "MX"
  content  = "feedback-smtp.us-east-1.amazonses.com"
  priority = 10
  ttl      = 300
  comment  = "AWS SES custom MAIL FROM - bounce handling"
}

resource "cloudflare_record" "ses_mail_from_spf" {
  zone_id = var.cloudflare_zone_id
  name    = "mail"
  type    = "TXT"
  content = "v=spf1 include:amazonses.com ~all"
  ttl     = 300
  comment = "AWS SES custom MAIL FROM - SPF for bounce subdomain"
}

# =============================================================================
# DNS Records - Security
# =============================================================================

# CAA - Only Let's Encrypt may issue TLS certificates for this domain
resource "cloudflare_record" "caa_letsencrypt" {
  zone_id = var.cloudflare_zone_id
  name    = "diegonmarcos.com"
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
