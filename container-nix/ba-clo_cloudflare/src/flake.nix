{
  description = "Cloudflare Infrastructure - DNS, Firewall, SSL configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "diegonmarcos.com";
      # IPs from cloud_architecture.json
      ips = {
        gcp-E2-f_0 = "35.226.147.64";      # Central Caddy Proxy
        oci-E2-f_0 = "130.110.251.193";    # Mail Server
        oci-E2-f_1 = "129.151.228.66";     # Analytics
        oci-A1-f_1 = "144.24.196.72";       # Dev Server
      };
    };

    # Main Terraform configuration
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

      # =============================================================================
      # DNS Records - All HTTP traffic routes through GCP Caddy Proxy
      # =============================================================================

      # Root domain -> GCP Caddy
      resource "cloudflare_record" "root" {
        zone_id = var.cloudflare_zone_id
        name    = "@"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300  # Auto when proxied
      }

      # www -> GCP Caddy
      resource "cloudflare_record" "www" {
        zone_id = var.cloudflare_zone_id
        name    = "www"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
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
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Authelia 2FA - direct on GCP"
      }

      # Analytics (Matomo) - via Caddy to oci-analytics
      resource "cloudflare_record" "analytics" {
        zone_id = var.cloudflare_zone_id
        name    = "analytics"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Matomo Analytics - via Caddy to oci-analytics"
      }

      # PhotoPrism - via Caddy to oci-apps-1
      resource "cloudflare_record" "photos" {
        zone_id = var.cloudflare_zone_id
        name    = "photos"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "PhotoPrism - via Caddy to oci-apps-1"
      }

      # Syncthing - via Caddy to oci-mail
      resource "cloudflare_record" "sync" {
        zone_id = var.cloudflare_zone_id
        name    = "sync"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Syncthing - via Caddy to oci-mail"
      }

      # Calendar (Radicale) - via Caddy to oci-apps-1
      resource "cloudflare_record" "cal" {
        zone_id = var.cloudflare_zone_id
        name    = "cal"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Radicale Calendar - via Caddy to oci-apps-1"
      }

      # Code Server IDE - via Caddy to oci-apps-1
      resource "cloudflare_record" "ide" {
        zone_id = var.cloudflare_zone_id
        name    = "ide"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Code Server IDE - via Caddy to oci-apps-1"
      }

      # NocoDB - via Caddy to oci-apps-1
      resource "cloudflare_record" "db" {
        zone_id = var.cloudflare_zone_id
        name    = "db"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "NocoDB - via Caddy to oci-apps-1"
      }

      # Ntfy Push Notifications - via Caddy on GCP
      resource "cloudflare_record" "rss" {
        zone_id = var.cloudflare_zone_id
        name    = "rss"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Ntfy push notifications - via Caddy on GCP"
      }

      # Caddy Admin Proxy
      resource "cloudflare_record" "proxy" {
        zone_id = var.cloudflare_zone_id
        name    = "proxy"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Caddy admin UI"
      }

      # Vaultwarden - via Caddy on GCP
      resource "cloudflare_record" "vault" {
        zone_id = var.cloudflare_zone_id
        name    = "vault"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Vaultwarden password manager - via Caddy on GCP"
      }

      # Grist Sheets - via Caddy to oci-apps-1
      resource "cloudflare_record" "sheets" {
        zone_id = var.cloudflare_zone_id
        name    = "sheets"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Grist Sheets - via Caddy to oci-apps-1"
      }

      # AFFiNE Drive - via Caddy to oci-apps-1
      resource "cloudflare_record" "drive_notes_affine" {
        zone_id = var.cloudflare_zone_id
        name    = "drive-notes-affine"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "AFFiNE workspace - via Caddy to oci-apps-1"
      }

      # Suite - static site via Caddy to GitHub Pages
      resource "cloudflare_record" "suite" {
        zone_id = var.cloudflare_zone_id
        name    = "suite"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
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
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Linktree - via Caddy to GitHub Pages"
      }

      # Cloud dashboard - via Caddy to GitHub Pages
      resource "cloudflare_record" "cloud" {
        zone_id = var.cloudflare_zone_id
        name    = "cloud"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Cloud dashboard - via Caddy to GitHub Pages"
      }

      # Nexus - via Caddy to GitHub Pages
      resource "cloudflare_record" "nexus" {
        zone_id = var.cloudflare_zone_id
        name    = "nexus"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Nexus - via Caddy to GitHub Pages"
      }

      # API - Flask + Rust on GCP
      resource "cloudflare_record" "api" {
        zone_id = var.cloudflare_zone_id
        name    = "api"
        type    = "A"
        content   = "${config.ips.gcp-E2-f_0}"
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
        content   = "${config.ips.gcp-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "Mailu webmail - via Caddy to oci-mail"
      }

      # SMTP direct (cannot be proxied)
      resource "cloudflare_record" "smtp" {
        zone_id = var.cloudflare_zone_id
        name    = "smtp"
        type    = "A"
        content   = "${config.ips.oci-E2-f_0}"
        proxied = false
        ttl     = 300
        comment = "SMTP direct - cannot proxy email traffic"
      }

      # MX Record
      resource "cloudflare_record" "mx" {
        zone_id  = var.cloudflare_zone_id
        name     = "@"
        type     = "MX"
        content    = "smtp.${config.domain}"
        priority = 10
        ttl      = 300
      }

      # SPF Record
      resource "cloudflare_record" "spf" {
        zone_id = var.cloudflare_zone_id
        name    = "@"
        type    = "TXT"
        content   = "v=spf1 mx a:smtp.${config.domain} -all"
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
        content   = "v=DMARC1; p=reject; rua=mailto:postmaster@${config.domain}"
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
        target   = "*.${config.domain}/*"
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
    '';

    # Variables template
    mkTfvarsTemplate = pkgs: pkgs.writeText "terraform.tfvars.template" ''
      # Cloudflare Configuration
      # Get API token from: https://dash.cloudflare.com/profile/api-tokens
      # Required permissions: Zone:DNS:Edit, Zone:Settings:Edit

      cloudflare_api_token = "CHANGE_ME_API_TOKEN"
      cloudflare_zone_id   = "CHANGE_ME_ZONE_ID"

      # DKIM key from Mailu: cat /opt/mailu/dkim/${config.domain}.dkim.key
      dkim_public_key = "v=DKIM1; k=rsa; p=CHANGE_ME_DKIM_KEY"
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
