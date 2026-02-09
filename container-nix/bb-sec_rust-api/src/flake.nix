{
  description = "Cloud Rust API - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "api.diegonmarcos.com";
      container_name = "rust-api";
      port = 8080;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        rust-api:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:8080"
          volumes:
            - /home/diego/cloud/architecture.json:/app/config/architecture.json:ro
            - ~/.ssh:/home/appuser/.ssh:ro
            - /home/diego/cloud/oci_config:/app/config/oci_config:ro
            - /home/diego/cloud/oci_api_key.pem:/app/config/oci_api_key.pem:ro
          environment:
            - RUST_API_PORT=8080
            - RUST_LOG=rust_api=info
            - CLOUD_CONFIG_PATH=/app/config/architecture.json
            - OCI_CONFIG_FILE=/app/config/oci_config
            - OCI_KEY_FILE=/app/config/oci_api_key.pem
            - OCI_FLEX1_INSTANCE_ID=''${OCI_FLEX1_INSTANCE_ID}
            - OCI_MICRO1_INSTANCE_ID=''${OCI_MICRO1_INSTANCE_ID}
            - OCI_MICRO2_INSTANCE_ID=''${OCI_MICRO2_INSTANCE_ID}
            - CF_API_TOKEN=''${CF_API_TOKEN}
            - CF_ZONE_ID=''${CF_ZONE_ID}
            - SSH_KEY_PATH=/app/config/id_rsa
            - GCP_SSH_KEY_PATH=/app/config/gcp_key
          networks:
            - npm_default
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8080/rust/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "rust-api-configs" {} ''
        mkdir -p $out/src/src $out/src/src/routes $out/src/src/services $out/src/src/models
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        # Cargo project
        cp ${./src/Cargo.toml} $out/src/Cargo.toml
        # Source files
        cp ${./src/src/main.rs} $out/src/src/main.rs
        cp ${./src/src/config.rs} $out/src/src/config.rs
        cp ${./src/src/error.rs} $out/src/src/error.rs
        # Models
        cp ${./src/src/models/mod.rs} $out/src/src/models/mod.rs
        cp ${./src/src/models/vm.rs} $out/src/src/models/vm.rs
        cp ${./src/src/models/wake.rs} $out/src/src/models/wake.rs
        cp ${./src/src/models/api_response.rs} $out/src/src/models/api_response.rs
        # Services
        cp ${./src/src/services/mod.rs} $out/src/src/services/mod.rs
        cp ${./src/src/services/oci.rs} $out/src/src/services/oci.rs
        cp ${./src/src/services/gcp.rs} $out/src/src/services/gcp.rs
        cp ${./src/src/services/ssh.rs} $out/src/src/services/ssh.rs
        cp ${./src/src/services/cloudflare.rs} $out/src/src/services/cloudflare.rs
        # Routes
        cp ${./src/src/routes/mod.rs} $out/src/src/routes/mod.rs
        cp ${./src/src/routes/health.rs} $out/src/src/routes/health.rs
        cp ${./src/src/routes/vm_control.rs} $out/src/src/routes/vm_control.rs
        cp ${./src/src/routes/vm_status.rs} $out/src/src/routes/vm_status.rs
        cp ${./src/src/routes/wake.rs} $out/src/src/routes/wake.rs
        cp ${./src/src/routes/containers.rs} $out/src/src/routes/containers.rs
        cp ${./src/src/routes/flex.rs} $out/src/src/routes/flex.rs
        cp ${./src/src/routes/cloudflare.rs} $out/src/src/routes/cloudflare.rs
      '';
    });
  };
}
