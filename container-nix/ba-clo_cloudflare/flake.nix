{
  description = "Cloudflare Infrastructure - DNS, Firewall, SSL configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "diegonmarcos.com";
      # IPs from cloud_architecture.json
      ips = {
        gcp-f-micro_1 = "35.226.147.64";      # Central NPM Proxy
        oci-f-micro_1 = "130.110.251.193";    # Mail Server
        oci-f-micro_2 = "129.151.228.66";     # Analytics
        oci-p-flex_1 = "144.24.196.72";       # Dev Server
      };
    };

    # Main Terraform configuration
    mainTf = pkgs.writeText "main.tf" ''
      terraform {
        required_providers {
          cloudflare = {
            source  = "cloudflare/cloudflare"
            version = "~> 4.0"
          }
        }
      }

      provider "cloudflare" {
        api_token = var.cloudflare_api_token
      }

      variable "cloudflare_api_token" {
        description = "Cloudflare API token with Zone:Edit permissions"
        type        = string
        sensitive   = true
      }

      variable "cloudflare_zone_id" {
        description = "Cloudflare Zone ID for ${config.domain}"
        type        = string
      }

      # =============================================================================
      # DNS Records - All traffic routes through GCP Central Proxy (NPM)
      # =============================================================================

      # Root domain -> GCP NPM
      resource "cloudflare_record" "root" {
        zone_id = var.cloudflare_zone_id
        name    = "@"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1  # Auto when proxied
      }

      # www -> GCP NPM
      resource "cloudflare_record" "www" {
        zone_id = var.cloudflare_zone_id
        name    = "www"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
      }

      # =============================================================================
      # Service Subdomains - All proxied through GCP NPM
      # =============================================================================

      # Authentication
      resource "cloudflare_record" "auth" {
        zone_id = var.cloudflare_zone_id
        name    = "auth"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "Authelia 2FA - direct on GCP"
      }

      # Analytics (Matomo) - via NPM
      resource "cloudflare_record" "analytics" {
        zone_id = var.cloudflare_zone_id
        name    = "analytics"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "Matomo Analytics - proxied via NPM to OCI Micro 2"
      }

      # Photos (Photoprism) - via NPM
      resource "cloudflare_record" "photos" {
        zone_id = var.cloudflare_zone_id
        name    = "photos"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "Photoprism - proxied via NPM to OCI Flex"
      }

      # Calendar (Radicale) - via NPM
      resource "cloudflare_record" "cal" {
        zone_id = var.cloudflare_zone_id
        name    = "cal"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "Radicale Calendar - proxied via NPM to OCI Flex"
      }

      # Web IDE (Code Server) - via NPM
      resource "cloudflare_record" "ide" {
        zone_id = var.cloudflare_zone_id
        name    = "ide"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "Code Server IDE - proxied via NPM to OCI Flex"
      }

      # NocoDB - via NPM
      resource "cloudflare_record" "db" {
        zone_id = var.cloudflare_zone_id
        name    = "db"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "NocoDB - proxied via NPM to OCI Flex"
      }

      # Ntfy Push Notifications - via NPM
      resource "cloudflare_record" "rss" {
        zone_id = var.cloudflare_zone_id
        name    = "rss"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "Ntfy push notifications"
      }

      # NPM Admin Proxy
      resource "cloudflare_record" "proxy" {
        zone_id = var.cloudflare_zone_id
        name    = "proxy"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "NPM Admin UI"
      }

      # AFFiNE Drive - via NPM
      resource "cloudflare_record" "drive" {
        zone_id = var.cloudflare_zone_id
        name    = "drive"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "AFFiNE workspace - proxied via NPM to OCI Flex"
      }

      # =============================================================================
      # Mail Records - Direct to OCI Micro 1 (not proxied for SMTP)
      # =============================================================================

      # Mail webmail interface - via NPM
      resource "cloudflare_record" "mail" {
        zone_id = var.cloudflare_zone_id
        name    = "mail"
        type    = "A"
        content   = "${config.ips.gcp-f-micro_1}"
        proxied = true
        ttl     = 1
        comment = "Mailu webmail - proxied via NPM"
      }

      # SMTP direct (cannot be proxied)
      resource "cloudflare_record" "smtp" {
        zone_id = var.cloudflare_zone_id
        name    = "smtp"
        type    = "A"
        content   = "${config.ips.oci-f-micro_1}"
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
          ssl                      = "full_strict"
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
        value = "14 DNS records configured"
      }
    '';

    # Variables template
    tfvarsTemplate = pkgs.writeText "terraform.tfvars.template" ''
      # Cloudflare Configuration
      # Get API token from: https://dash.cloudflare.com/profile/api-tokens
      # Required permissions: Zone:DNS:Edit, Zone:Settings:Edit

      cloudflare_api_token = "CHANGE_ME_API_TOKEN"
      cloudflare_zone_id   = "CHANGE_ME_ZONE_ID"

      # DKIM key from Mailu: cat /opt/mailu/dkim/${config.domain}.dkim.key
      dkim_public_key = "v=DKIM1; k=rsa; p=CHANGE_ME_DKIM_KEY"
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "cloudflare-terraform" {} ''
        mkdir -p $out
        cp ${mainTf} $out/main.tf
        cp ${tfvarsTemplate} $out/terraform.tfvars.template

        cat > $out/README.md << 'EOF'
# Cloudflare Terraform Configuration

## Setup
1. Copy terraform.tfvars.template to terraform.tfvars
2. Fill in your Cloudflare API token and Zone ID
3. Update DKIM key from Mailu

## Usage
```bash
terraform init
terraform plan
terraform apply
```

## DNS Summary
- All web traffic routes through GCP NPM (35.226.147.64)
- SMTP traffic goes direct to OCI Micro 1 (130.110.251.193)
- Email records: MX, SPF, DKIM, DMARC configured
EOF
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.opentofu pkgs.terraform ];
    };
  };
}
