# Cloudflare DNS, Email Routing, Tunnel — data-driven from terraform.json
# All record values live in terraform.json; this file is a pure template.

locals {
  config = jsondecode(file("${path.module}/terraform.json"))
  dns    = local.config.dns_records
}

# =============================================================================
# Provider
# =============================================================================

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

# ── Variables (secrets + DKIM keys — injected via tfvars) ────────────────────

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

variable "dkim_stalwart_public_key" {
  description = "Stalwart DKIM public key (dkim._domainkey)"
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

# Map variable names to values for dynamic DKIM lookup
locals {
  dkim_vars = {
    dkim_stalwart_public_key = var.dkim_stalwart_public_key
    dkim_cf_public_key       = var.dkim_cf_public_key
    dkim_google_public_key   = var.dkim_google_public_key
  }

  ses_dkim_tokens = {
    ses_dkim_token_1 = var.ses_dkim_token_1
    ses_dkim_token_2 = var.ses_dkim_token_2
    ses_dkim_token_3 = var.ses_dkim_token_3
  }
}

# =============================================================================
# DNS Records — A records (all point to proxy_ip)
# =============================================================================

resource "cloudflare_record" "a_records" {
  for_each = { for idx, r in local.dns.a_records : r.name => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "A"
  content = local.config.proxy_ip
  proxied = each.value.proxied
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — CNAME records
# =============================================================================

resource "cloudflare_record" "cname_records" {
  for_each = { for r in local.dns.cname_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "CNAME"
  content = each.value.content
  proxied = each.value.proxied
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — TXT records (SPF, DMARC, SES SPF)
# =============================================================================

resource "cloudflare_record" "txt_records" {
  for_each = { for r in local.dns.txt_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "TXT"
  content = each.value.content
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — DKIM TXT records (content from variables)
# =============================================================================

resource "cloudflare_record" "dkim_records" {
  for_each = { for r in local.dns.dkim_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "TXT"
  content = local.dkim_vars[each.value.var]
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — AWS SES verification + DKIM CNAMEs
# =============================================================================

resource "cloudflare_record" "ses_verification" {
  zone_id = var.cloudflare_zone_id
  name    = local.dns.ses_verification.name
  type    = "TXT"
  content = var.ses_verification_token
  ttl     = local.dns.ses_verification.ttl
  comment = local.dns.ses_verification.comment
}

resource "cloudflare_record" "ses_dkim" {
  for_each = { for r in local.dns.ses_dkim_cnames : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = "${local.ses_dkim_tokens[each.value.var]}._domainkey"
  type    = "CNAME"
  content = "${local.ses_dkim_tokens[each.value.var]}.dkim.amazonses.com"
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# DNS Records — SES MAIL FROM (MX + SPF already in txt_records)
# =============================================================================

resource "cloudflare_record" "ses_mail_from_mx" {
  zone_id  = var.cloudflare_zone_id
  name     = local.dns.ses_mail_from_mx.name
  type     = "MX"
  content  = local.dns.ses_mail_from_mx.content
  priority = local.dns.ses_mail_from_mx.priority
  ttl      = local.dns.ses_mail_from_mx.ttl
  comment  = local.dns.ses_mail_from_mx.comment
}

# =============================================================================
# DNS Records — CAA
# =============================================================================

resource "cloudflare_record" "caa_records" {
  for_each = { for r in local.dns.caa_records : r.key => r }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "CAA"
  data {
    flags = each.value.flags
    tag   = each.value.tag
    value = each.value.value
  }
  ttl     = each.value.ttl
  comment = each.value.comment
}

# =============================================================================
# Cloudflare Tunnel
# =============================================================================

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "tunnels" {
  account_id = local.config.account_id
  tunnel_id  = local.config.tunnel.id

  config {
    dynamic "ingress_rule" {
      for_each = local.config.tunnel.ingress_rules
      content {
        hostname = ingress_rule.value.hostname
        service  = ingress_rule.value.service
      }
    }
    # Catch-all (required by Cloudflare)
    ingress_rule {
      service = local.config.tunnel.catchall_service
    }
  }
}

# =============================================================================
# Email Routing
# =============================================================================

resource "cloudflare_email_routing_address" "backup" {
  account_id = local.config.account_id
  email      = local.config.email_routing.backup_email
}

resource "cloudflare_email_routing_rule" "rules" {
  for_each = { for idx, r in local.config.email_routing.rules : r.name => r }

  zone_id  = var.cloudflare_zone_id
  name     = each.value.name
  enabled  = each.value.enabled
  priority = each.value.priority

  matcher {
    type  = each.value.match_type
    field = each.value.match_field
    value = each.value.match_value
  }

  action {
    type  = each.value.action_type
    value = each.value.action_value
  }
}

# =============================================================================
# SSL/TLS Settings
# =============================================================================

resource "cloudflare_zone_settings_override" "ssl_settings" {
  zone_id = var.cloudflare_zone_id

  settings {
    ssl                      = local.config.ssl_settings.ssl
    always_use_https         = local.config.ssl_settings.always_use_https
    min_tls_version          = local.config.ssl_settings.min_tls_version
    automatic_https_rewrites = local.config.ssl_settings.automatic_https_rewrites
    opportunistic_encryption = local.config.ssl_settings.opportunistic_encryption
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "email_architecture" {
  value = "CF Email Routing (MX) → Worker email-forwarder → smtp-proxy (oci-mail:8080) → Stalwart :25"
}
