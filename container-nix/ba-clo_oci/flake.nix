{
  description = "Oracle Cloud Infrastructure - Security Lists, VCN, VM configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      region = "eu-marseille-1";
      tenancy_ocid = "CHANGE_ME_TENANCY_OCID";
      compartment_ocid = "CHANGE_ME_COMPARTMENT_OCID";

      # VM Instance OCIDs
      instances = {
        oci-f-micro_1 = {
          ocid = "ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacbwylmkqr253ay7binepapgsyopllfayovkzaky6oigbq";
          ip = "130.110.251.193";
          name = "OCI Free Micro 1 - Mail Server";
        };
        oci-f-micro_2 = {
          ocid = "ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczacgwg5rkrjyomuxvjtvtuk5xrbmy7hmslwn4pse4kw5jkq";
          ip = "129.151.228.66";
          name = "OCI Free Micro 2 - Analytics";
        };
        oci-p-flex_1 = {
          ocid = "ocid1.instance.oc1.eu-marseille-1.anwxeljruadvczach3pczd4kn6w5stdt7rs64u2uqexzor6lyneaebc2i2ra";
          ip = "144.24.196.72";
          name = "OCI Paid Flex 1 - Dev Server";
        };
      };

      # GCP IP for proxy whitelisting
      gcp_ip = "35.226.147.64";
    };

    # Main Terraform configuration
    mainTf = pkgs.writeText "main.tf" ''
      terraform {
        required_providers {
          oci = {
            source  = "oracle/oci"
            version = "~> 5.0"
          }
        }
      }

      provider "oci" {
        region = var.region
        # Auth via ~/.oci/config or environment variables
      }

      variable "region" {
        description = "OCI Region"
        type        = string
        default     = "${config.region}"
      }

      variable "tenancy_ocid" {
        description = "OCI Tenancy OCID"
        type        = string
      }

      variable "compartment_ocid" {
        description = "OCI Compartment OCID"
        type        = string
      }

      variable "gcp_proxy_ip" {
        description = "GCP Central Proxy IP for whitelisting"
        type        = string
        default     = "${config.gcp_ip}"
      }

      # =============================================================================
      # VCN (Virtual Cloud Network)
      # =============================================================================

      resource "oci_core_vcn" "main" {
        compartment_id = var.compartment_ocid
        cidr_blocks    = ["10.0.0.0/16"]
        display_name   = "main-vcn"
        dns_label      = "mainvcn"
      }

      resource "oci_core_internet_gateway" "main" {
        compartment_id = var.compartment_ocid
        vcn_id         = oci_core_vcn.main.id
        display_name   = "main-igw"
        enabled        = true
      }

      resource "oci_core_route_table" "main" {
        compartment_id = var.compartment_ocid
        vcn_id         = oci_core_vcn.main.id
        display_name   = "main-rt"

        route_rules {
          destination       = "0.0.0.0/0"
          destination_type  = "CIDR_BLOCK"
          network_entity_id = oci_core_internet_gateway.main.id
        }
      }

      # =============================================================================
      # Security List - Mail Server (oci-f-micro_1)
      # =============================================================================

      resource "oci_core_security_list" "mail_server" {
        compartment_id = var.compartment_ocid
        vcn_id         = oci_core_vcn.main.id
        display_name   = "mail-server-security-list"

        # Egress - Allow all outbound
        egress_security_rules {
          destination = "0.0.0.0/0"
          protocol    = "all"
          stateless   = false
        }

        # SSH
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "6"  # TCP
          stateless = false
          tcp_options {
            min = 22
            max = 22
          }
        }

        # SMTP (25)
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 25
            max = 25
          }
        }

        # SMTP Submission (587)
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 587
            max = 587
          }
        }

        # IMAPS (993)
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 993
            max = 993
          }
        }

        # HTTPS (443) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 443
            max = 443
          }
        }

        # HTTP (8080) - Mailu admin from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 8080
            max = 8080
          }
        }

        # ICMP
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "1"
          stateless = false
          icmp_options {
            type = 3
            code = 4
          }
        }

        ingress_security_rules {
          source   = "10.0.0.0/16"
          protocol = "1"
          stateless = false
          icmp_options {
            type = 3
          }
        }
      }

      # =============================================================================
      # Security List - Analytics Server (oci-f-micro_2)
      # =============================================================================

      resource "oci_core_security_list" "analytics_server" {
        compartment_id = var.compartment_ocid
        vcn_id         = oci_core_vcn.main.id
        display_name   = "analytics-server-security-list"

        # Egress - Allow all outbound
        egress_security_rules {
          destination = "0.0.0.0/0"
          protocol    = "all"
          stateless   = false
        }

        # SSH
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 22
            max = 22
          }
        }

        # HTTP (80) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 80
            max = 80
          }
        }

        # HTTPS (443) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 443
            max = 443
          }
        }

        # Matomo (8080) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 8080
            max = 8080
          }
        }

        # ICMP
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "1"
          stateless = false
          icmp_options {
            type = 3
            code = 4
          }
        }
      }

      # =============================================================================
      # Security List - Dev Server (oci-p-flex_1)
      # =============================================================================

      resource "oci_core_security_list" "dev_server" {
        compartment_id = var.compartment_ocid
        vcn_id         = oci_core_vcn.main.id
        display_name   = "dev-server-security-list"

        # Egress - Allow all outbound
        egress_security_rules {
          destination = "0.0.0.0/0"
          protocol    = "all"
          stateless   = false
        }

        # SSH
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 22
            max = 22
          }
        }

        # HTTPS (443) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 443
            max = 443
          }
        }

        # Photoprism (2342) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 2342
            max = 2342
          }
        }

        # Radicale (5232) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 5232
            max = 5232
          }
        }

        # Code Server (8443) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 8443
            max = 8443
          }
        }

        # NocoDB (8085) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 8085
            max = 8085
          }
        }

        # AFFiNE (3010) - from GCP proxy
        ingress_security_rules {
          source   = "$${var.gcp_proxy_ip}/32"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 3010
            max = 3010
          }
        }

        # Syncthing (22000) - direct access
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "6"
          stateless = false
          tcp_options {
            min = 22000
            max = 22000
          }
        }

        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "17"  # UDP
          stateless = false
          udp_options {
            min = 22000
            max = 22000
          }
        }

        # Syncthing Discovery (21027)
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "17"
          stateless = false
          udp_options {
            min = 21027
            max = 21027
          }
        }

        # ICMP
        ingress_security_rules {
          source   = "0.0.0.0/0"
          protocol = "1"
          stateless = false
          icmp_options {
            type = 3
            code = 4
          }
        }
      }

      # =============================================================================
      # Outputs
      # =============================================================================

      output "vcn_id" {
        value       = oci_core_vcn.main.id
        description = "VCN OCID"
      }

      output "security_lists" {
        value = {
          mail_server      = oci_core_security_list.mail_server.id
          analytics_server = oci_core_security_list.analytics_server.id
          dev_server       = oci_core_security_list.dev_server.id
        }
        description = "Security List OCIDs"
      }

      output "instance_info" {
        value = {
          "oci-f-micro_1" = {
            ip   = "${config.instances.oci-f-micro_1.ip}"
            ocid = "${config.instances.oci-f-micro_1.ocid}"
            role = "Mail Server"
          }
          "oci-f-micro_2" = {
            ip   = "${config.instances.oci-f-micro_2.ip}"
            ocid = "${config.instances.oci-f-micro_2.ocid}"
            role = "Analytics"
          }
          "oci-p-flex_1" = {
            ip   = "${config.instances.oci-p-flex_1.ip}"
            ocid = "${config.instances.oci-p-flex_1.ocid}"
            role = "Dev Server"
          }
        }
        description = "Instance information"
      }
    '';

    # Variables template
    tfvarsTemplate = pkgs.writeText "terraform.tfvars.template" ''
      # Oracle Cloud Configuration
      # Get these from OCI Console or ~/.oci/config

      tenancy_ocid     = "ocid1.tenancy.oc1..CHANGE_ME"
      compartment_ocid = "ocid1.compartment.oc1..CHANGE_ME"
      region           = "${config.region}"

      # GCP Proxy IP (update if it changes)
      gcp_proxy_ip = "${config.gcp_ip}"
    '';

    # OCI CLI config template
    ociConfigTemplate = pkgs.writeText "oci-config.template" ''
      [DEFAULT]
      user=ocid1.user.oc1..CHANGE_ME
      fingerprint=CHANGE_ME:fingerprint
      tenancy=ocid1.tenancy.oc1..CHANGE_ME
      region=${config.region}
      key_file=/home/diego/Mounts/Git/vault/A0_keys/oci/oci_api_key.pem
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "oci-terraform" {} ''
        mkdir -p $out
        cp ${mainTf} $out/main.tf
        cp ${tfvarsTemplate} $out/terraform.tfvars.template
        cp ${ociConfigTemplate} $out/oci-config.template

        cat > $out/README.md << 'EOF'
# Oracle Cloud Infrastructure Terraform Configuration

## VMs Managed
- **oci-f-micro_1** (130.110.251.193): Mail Server (Mailu)
- **oci-f-micro_2** (129.151.228.66): Analytics (Matomo)
- **oci-p-flex_1** (144.24.196.72): Dev Server (Photoprism, Radicale, Code Server, NocoDB, AFFiNE)

## Security Architecture
- All web traffic from GCP proxy only (35.226.147.64)
- SSH open to all (consider restricting)
- Mail ports (25, 587, 993) open to all
- Service ports restricted to GCP proxy IP

## Setup
1. Copy terraform.tfvars.template to terraform.tfvars
2. Fill in your tenancy and compartment OCIDs
3. Ensure ~/.oci/config is configured

## Usage
```bash
terraform init
terraform plan
terraform apply
```

## IP Change Management
When GCP IP changes, update gcp_proxy_ip variable and re-apply.
EOF
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.opentofu pkgs.terraform pkgs.oci-cli ];
    };
  };
}
