{
  description = "Cloudflare Infrastructure - DNS, Email Routing, SSL configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "diegonmarcos.com";
      # IPs from cloud_architecture.json
      ips = {
        gcp-E2-f_0  = "35.226.147.64";      # Central Caddy Proxy
        oci-E2-f_0  = "130.110.251.193";    # Mail Server (oci-mail)
        oci-E2-f_1  = "129.151.228.66";     # Analytics
        oci-A1-f_1  = "144.24.196.72";      # Dev Server (oci-apps-1)
      };
      # Cloudflare Tunnel for smtp-proxy (alternative to direct port 8080)
      smtpProxyTunnel = "90b644ed-1339-4fbe-a467-687012aa84ae.cfargotunnel.com";
    };

    # =========================================================================
    # Email Architecture (DO NOT CHANGE without understanding full flow):
    #
    #   INBOUND:
    #     Sender → Cloudflare MX (route1/2/3.mx.cloudflare.net)
    #       → Email Routing rule: me@diegonmarcos.com → Worker "email-forwarder"
    #       → POST to smtp-proxy (oci-mail:8080, open to 0.0.0.0/0 in OCI security list)
    #       → smtp-proxy relays to Mailu front:25
    #     Fallback: forward to diegonmarcos@live.com if smtp-proxy fails
    #
    #   OUTBOUND:
    #     Mailu → smtp.diegonmarcos.com (oci-mail:465/587) → recipients
    #
    #   EMAIL ROUTING RULES (managed in CF Dashboard, NOT Terraform):
    #     me@diegonmarcos.com → Worker "email-forwarder"  (priority 0)
    #     catch-all → drop (disabled)
    #
    #   WORKER SOURCE: a_solutions/ba-clo_cloudflare-worker/
    # =========================================================================

    mkMainTf = pkgs: pkgs.writeText "main.tf" ''
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
        description = "Cloudflare Zone ID for ${config.domain}"
        type        = string
      }

      variable "dkim_mailu_public_key" {
        description = "Mailu DKIM public key (dkim._domainkey)"
        type        = string
        default     = "v=DKIM1; k=rsa; p=CHANGE_ME"
      }

      variable "dkim_cf_public_key" {
        description = "Cloudflare Email Routing DKIM key (cf2024-1._domainkey)"
        type        = string
        default     = "v=DKIM1; h=sha256; k=rsa; p=CHANGE_ME"
      }

      variable "dkim_google_public_key" {
        description = "Google Workspace DKIM key (google._domainkey)"
        type        = string
        default     = "v=DKIM1; k=rsa; p=CHANGE_ME"
      }

      variable "dkim_mail_public_key" {
        description = "Mailu legacy DKIM key (mail._domainkey)"
        type        = string
        default     = "v=DKIM1; k=rsa; p=CHANGE_ME"
      }

      # =============================================================================
      # DNS Records - Root & Wildcard
      # =============================================================================

      resource "cloudflare_record" "root" {
        zone_id = var.cloudflare_zone_id
        name    = "@"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
      }

      resource "cloudflare_record" "www" {
        zone_id = var.cloudflare_zone_id
        name    = "www"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
      }

      resource "cloudflare_record" "wildcard" {
        zone_id = var.cloudflare_zone_id
        name    = "*"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 1
        comment = "Wildcard catch-all → GCP Caddy"
      }

      # =============================================================================
      # DNS Records - Service Subdomains (all via GCP Caddy → WireGuard → target VM)
      # =============================================================================

      resource "cloudflare_record" "auth" {
        zone_id = var.cloudflare_zone_id
        name    = "auth"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Authelia 2FA"
      }

      resource "cloudflare_record" "analytics" {
        zone_id = var.cloudflare_zone_id
        name    = "analytics"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Matomo Analytics via Caddy → oci-analytics"
      }

      resource "cloudflare_record" "photos" {
        zone_id = var.cloudflare_zone_id
        name    = "photos"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "PhotoPrism via Caddy → oci-apps-1"
      }

      resource "cloudflare_record" "sync" {
        zone_id = var.cloudflare_zone_id
        name    = "sync"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Syncthing via Caddy → oci-mail"
      }

      resource "cloudflare_record" "cal" {
        zone_id = var.cloudflare_zone_id
        name    = "cal"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Radicale Calendar via Caddy → oci-mail"
      }

      resource "cloudflare_record" "ide" {
        zone_id = var.cloudflare_zone_id
        name    = "ide"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Code Server IDE via Caddy → oci-apps-1"
      }

      resource "cloudflare_record" "db" {
        zone_id = var.cloudflare_zone_id
        name    = "db"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "NocoDB via Caddy → oci-apps-1"
      }

      resource "cloudflare_record" "rss" {
        zone_id = var.cloudflare_zone_id
        name    = "rss"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Ntfy push notifications via Caddy on GCP"
      }

      resource "cloudflare_record" "proxy" {
        zone_id = var.cloudflare_zone_id
        name    = "proxy"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Caddy admin"
      }

      resource "cloudflare_record" "vault" {
        zone_id = var.cloudflare_zone_id
        name    = "vault"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Vaultwarden via Caddy on GCP"
      }

      resource "cloudflare_record" "sheets" {
        zone_id = var.cloudflare_zone_id
        name    = "sheets"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Grist Sheets via Caddy → oci-apps-1"
      }

      resource "cloudflare_record" "drive_notes_affine" {
        zone_id = var.cloudflare_zone_id
        name    = "drive-notes-affine"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "AFFiNE workspace via Caddy → oci-apps-1"
      }

      resource "cloudflare_record" "suite" {
        zone_id = var.cloudflare_zone_id
        name    = "suite"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
      }

      resource "cloudflare_record" "linktree" {
        zone_id = var.cloudflare_zone_id
        name    = "linktree"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
      }

      resource "cloudflare_record" "cloud" {
        zone_id = var.cloudflare_zone_id
        name    = "cloud"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
      }

      resource "cloudflare_record" "nexus" {
        zone_id = var.cloudflare_zone_id
        name    = "nexus"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
      }

      resource "cloudflare_record" "api" {
        zone_id = var.cloudflare_zone_id
        name    = "api"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Flask + Rust API via Caddy on GCP"
      }

      # =============================================================================
      # DNS Records - Mail (direct to oci-mail, cannot proxy SMTP ports)
      # =============================================================================

      resource "cloudflare_record" "mail" {
        zone_id = var.cloudflare_zone_id
        name    = "mail"
        type    = "A"
        content = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Mailu webmail via Caddy → oci-mail"
      }

      # SMTP direct - not proxied (Cloudflare cannot proxy SMTP ports)
      resource "cloudflare_record" "smtp" {
        zone_id = var.cloudflare_zone_id
        name    = "smtp"
        type    = "A"
        content = "${config.ips.oci-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "SMTP direct to oci-mail - used in SPF + outbound SMTP client config"
      }

      # IMAP direct - not proxied
      resource "cloudflare_record" "imap" {
        zone_id = var.cloudflare_zone_id
        name    = "imap"
        type    = "A"
        content = "${config.ips.oci-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "IMAP direct to oci-mail"
      }

      # SMTP proxy via Cloudflare Tunnel (alternative inbound path to port 8080)
      resource "cloudflare_record" "smtp_proxy_tunnel" {
        zone_id = var.cloudflare_zone_id
        name    = "smtp-proxy"
        type    = "CNAME"
        content = "${config.smtpProxyTunnel}"
        proxied = true
        ttl     = 1
        comment = "Cloudflare Tunnel → smtp-proxy on oci-mail (alternative to direct port 8080)"
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
      # MX Records - Cloudflare Email Routing
      # NOTE: Mail flows through Cloudflare Email Routing, NOT directly to Mailu.
      # CF receives on these MX servers, then Email Routing rules forward to the
      # Worker "email-forwarder" → smtp-proxy (oci-mail:8080) → Mailu front:25.
      # Worker source: a_solutions/ba-clo_cloudflare-worker/
      # =============================================================================

      resource "cloudflare_record" "mx_1" {
        zone_id  = var.cloudflare_zone_id
        name     = "@"
        type     = "MX"
        content  = "route1.mx.cloudflare.net"
        priority = 22
        ttl      = 1
        comment  = "Cloudflare Email Routing MX"
      }

      resource "cloudflare_record" "mx_2" {
        zone_id  = var.cloudflare_zone_id
        name     = "@"
        type     = "MX"
        content  = "route2.mx.cloudflare.net"
        priority = 85
        ttl      = 1
        comment  = "Cloudflare Email Routing MX"
      }

      resource "cloudflare_record" "mx_3" {
        zone_id  = var.cloudflare_zone_id
        name     = "@"
        type     = "MX"
        content  = "route3.mx.cloudflare.net"
        priority = 97
        ttl      = 1
        comment  = "Cloudflare Email Routing MX"
      }

      # =============================================================================
      # TXT Records - SPF, DKIM, DMARC
      # =============================================================================

      # SPF - one record only (RFC 7208: multiple SPF records = permerror)
      # include:_spf.mx.cloudflare.net → authorizes Cloudflare Email Routing forwarding
      # a:smtp.diegonmarcos.com → authorizes Mailu outbound SMTP (oci-mail)
      resource "cloudflare_record" "spf" {
        zone_id = var.cloudflare_zone_id
        name    = "@"
        type    = "TXT"
        content = "v=spf1 include:_spf.mx.cloudflare.net a:smtp.${config.domain} ~all"
        ttl     = 300
        comment = "SPF: CF Email Routing + Mailu outbound. ONE record only - multiple = permerror"
      }

      # DMARC
      resource "cloudflare_record" "dmarc" {
        zone_id = var.cloudflare_zone_id
        name    = "_dmarc"
        type    = "TXT"
        content = "v=DMARC1; p=reject; rua=mailto:postmaster@${config.domain}"
        ttl     = 300
      }

      # DKIM - Mailu (primary selector)
      resource "cloudflare_record" "dkim_mailu" {
        zone_id = var.cloudflare_zone_id
        name    = "dkim._domainkey"
        type    = "TXT"
        content = var.dkim_mailu_public_key
        ttl     = 300
        comment = "Mailu DKIM - get from Mailu admin > Domains > diegonmarcos.com > DKIM"
      }

      # DKIM - Cloudflare Email Routing (auto-managed by CF)
      resource "cloudflare_record" "dkim_cloudflare" {
        zone_id = var.cloudflare_zone_id
        name    = "cf2024-1._domainkey"
        type    = "TXT"
        content = var.dkim_cf_public_key
        ttl     = 1
        comment = "Cloudflare Email Routing DKIM (auto-managed by CF)"
      }

      # DKIM - Google Workspace
      resource "cloudflare_record" "dkim_google" {
        zone_id = var.cloudflare_zone_id
        name    = "google._domainkey"
        type    = "TXT"
        content = var.dkim_google_public_key
        ttl     = 1
        comment = "Google Workspace DKIM"
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

      output "smtp_proxy_access" {
        value = "Direct: http://smtp.diegonmarcos.com:8080/ (OCI security list TCP 8080 open to 0.0.0.0/0)"
      }

      output "smtp_proxy_tunnel" {
        value = "Tunnel: https://smtp-proxy.diegonmarcos.com/ (Cloudflare Tunnel alternative)"
      }
    '';

    mkTfvarsTemplate = pkgs: pkgs.writeText "terraform.tfvars.template" ''
      cloudflare_api_key   = "CHANGE_ME_API_KEY"
      cloudflare_email     = "me@diegonmarcos.com"
      cloudflare_zone_id   = "ff4335cc9c7de42e580d0dff9a0d70eb"

      # Get from Mailu admin > Domains > diegonmarcos.com > DKIM
      dkim_mailu_public_key  = "v=DKIM1; k=rsa; p=CHANGE_ME"

      # Get from Cloudflare Dashboard > Email > DKIM settings
      dkim_cf_public_key     = "v=DKIM1; h=sha256; k=rsa; p=CHANGE_ME"

      # Get from Google Workspace admin
      dkim_google_public_key = "v=DKIM1; k=rsa; p=CHANGE_ME"

      # Get from Mailu admin (legacy selector)
      dkim_mail_public_key   = "v=DKIM1; k=rsa; p=CHANGE_ME"
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "cloudflare-terraform" {} ''
        mkdir -p $out
        cp ${mkMainTf pkgs} $out/main.tf
        cp ${mkTfvarsTemplate pkgs} $out/terraform.tfvars.template
      '';
    });
  };
}
