{
  description = "Google Cloud Infrastructure - Firewall, VM, VPC configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      project_id = "CHANGE_ME_PROJECT_ID";
      region = "us-central1";
      zone = "us-central1-a";

      vm = {
        name = "arch-1";
        machine_type = "e2-micro";
        ip = "35.226.147.64";
      };

      # Allowed source IPs for admin access
      admin_ips = [
        "0.0.0.0/0"  # Or restrict to your IP
      ];
    };

    # Main Terraform configuration
    mainTf = pkgs.writeText "main.tf" ''
      terraform {
        required_providers {
          google = {
            source  = "hashicorp/google"
            version = "~> 5.0"
          }
        }
      }

      provider "google" {
        project = var.project_id
        region  = var.region
        zone    = var.zone
      }

      variable "project_id" {
        description = "GCP Project ID"
        type        = string
      }

      variable "region" {
        description = "GCP Region"
        type        = string
        default     = "${config.region}"
      }

      variable "zone" {
        description = "GCP Zone"
        type        = string
        default     = "${config.zone}"
      }

      # =============================================================================
      # VPC Network
      # =============================================================================

      resource "google_compute_network" "main" {
        name                    = "main-network"
        auto_create_subnetworks = true
      }

      # =============================================================================
      # Firewall Rules
      # =============================================================================

      # Allow SSH
      resource "google_compute_firewall" "allow_ssh" {
        name    = "allow-ssh"
        network = google_compute_network.main.name

        allow {
          protocol = "tcp"
          ports    = ["22"]
        }

        source_ranges = ["0.0.0.0/0"]
        target_tags   = ["ssh-enabled"]
        description   = "Allow SSH access"
      }

      # Allow HTTP/HTTPS (Web traffic)
      resource "google_compute_firewall" "allow_web" {
        name    = "allow-web"
        network = google_compute_network.main.name

        allow {
          protocol = "tcp"
          ports    = ["80", "443"]
        }

        source_ranges = ["0.0.0.0/0"]
        target_tags   = ["web-server"]
        description   = "Allow HTTP and HTTPS traffic"
      }

      # Allow NPM Admin (port 81)
      resource "google_compute_firewall" "allow_npm_admin" {
        name    = "allow-npm-admin"
        network = google_compute_network.main.name

        allow {
          protocol = "tcp"
          ports    = ["81"]
        }

        source_ranges = ["0.0.0.0/0"]  # Consider restricting to your IP
        target_tags   = ["npm-admin"]
        description   = "Allow NPM Admin UI access"
      }

      # Allow WireGuard VPN
      resource "google_compute_firewall" "allow_wireguard" {
        name    = "allow-wireguard"
        network = google_compute_network.main.name

        allow {
          protocol = "udp"
          ports    = ["51820"]
        }

        source_ranges = ["0.0.0.0/0"]
        target_tags   = ["wireguard"]
        description   = "Allow WireGuard VPN traffic"
      }

      # Allow Syslog from Oracle VMs
      resource "google_compute_firewall" "allow_syslog" {
        name    = "allow-syslog"
        network = google_compute_network.main.name

        allow {
          protocol = "tcp"
          ports    = ["514", "5514"]
        }

        allow {
          protocol = "udp"
          ports    = ["514"]
        }

        source_ranges = [
          "130.110.251.193/32",  # oci-f-micro_1
          "129.151.228.66/32",   # oci-f-micro_2
          "144.24.196.72/32"     # oci-p-flex_1
        ]
        target_tags   = ["syslog-server"]
        description   = "Allow syslog from Oracle VMs"
      }

      # Allow ICMP (ping)
      resource "google_compute_firewall" "allow_icmp" {
        name    = "allow-icmp"
        network = google_compute_network.main.name

        allow {
          protocol = "icmp"
        }

        source_ranges = ["0.0.0.0/0"]
        description   = "Allow ICMP for diagnostics"
      }

      # =============================================================================
      # Compute Instance
      # =============================================================================

      resource "google_compute_instance" "central_proxy" {
        name         = "${config.vm.name}"
        machine_type = "${config.vm.machine_type}"
        zone         = var.zone

        tags = ["ssh-enabled", "web-server", "npm-admin", "wireguard", "syslog-server"]

        boot_disk {
          initialize_params {
            image = "projects/arch-linux-gce/global/images/family/arch"
            size  = 30
            type  = "pd-standard"
          }
        }

        network_interface {
          network = google_compute_network.main.name

          access_config {
            # Ephemeral public IP - consider reserving static IP
            nat_ip = google_compute_address.static_ip.address
          }
        }

        metadata = {
          ssh-keys = "diego:$${file(var.ssh_public_key_path)}"
        }

        scheduling {
          preemptible       = false
          automatic_restart = true
        }

        service_account {
          scopes = ["cloud-platform"]
        }

        labels = {
          environment = "production"
          role        = "central-proxy"
          managed_by  = "terraform"
        }
      }

      # Static IP Address
      resource "google_compute_address" "static_ip" {
        name   = "central-proxy-ip"
        region = var.region
      }

      variable "ssh_public_key_path" {
        description = "Path to SSH public key"
        type        = string
        default     = "~/.ssh/id_rsa.pub"
      }

      # =============================================================================
      # Outputs
      # =============================================================================

      output "instance_ip" {
        value       = google_compute_address.static_ip.address
        description = "Public IP of the central proxy"
      }

      output "instance_name" {
        value       = google_compute_instance.central_proxy.name
        description = "Name of the compute instance"
      }

      output "ssh_command" {
        value       = "gcloud compute ssh ${config.vm.name} --zone ${config.zone}"
        description = "SSH command to connect"
      }

      output "firewall_rules" {
        value = [
          "allow-ssh (22/tcp)",
          "allow-web (80,443/tcp)",
          "allow-npm-admin (81/tcp)",
          "allow-wireguard (51820/udp)",
          "allow-syslog (514,5514/tcp+udp)",
          "allow-icmp"
        ]
        description = "Configured firewall rules"
      }
    '';

    # Variables template
    tfvarsTemplate = pkgs.writeText "terraform.tfvars.template" ''
      # Google Cloud Configuration
      # Authenticate: gcloud auth application-default login

      project_id = "CHANGE_ME_PROJECT_ID"
      region     = "${config.region}"
      zone       = "${config.zone}"

      ssh_public_key_path = "~/.ssh/id_rsa.pub"
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "gcloud-terraform" {} ''
        mkdir -p $out
        cp ${mainTf} $out/main.tf
        cp ${tfvarsTemplate} $out/terraform.tfvars.template

        cat > $out/README.md << 'EOF'
# Google Cloud Terraform Configuration

## Services on this VM (gcp-f-micro_1)
- NPM Reverse Proxy (central for all traffic)
- Authelia 2FA
- Flask API
- Vaultwarden
- Ntfy
- Syslog Central
- WireGuard VPN

## Setup
1. Authenticate: `gcloud auth application-default login`
2. Copy terraform.tfvars.template to terraform.tfvars
3. Fill in your project ID

## Usage
```bash
terraform init
terraform plan
terraform apply
```

## Firewall Summary
- SSH: 22/tcp (all sources)
- Web: 80,443/tcp (all sources)
- NPM Admin: 81/tcp (all sources - consider restricting)
- WireGuard: 51820/udp (all sources)
- Syslog: 514,5514/tcp+udp (Oracle VMs only)
EOF
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.opentofu pkgs.terraform pkgs.google-cloud-sdk ];
    };
  };
}
