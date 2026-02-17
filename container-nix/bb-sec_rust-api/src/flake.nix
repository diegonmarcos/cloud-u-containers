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
          image: ghcr.io/diegonmarcos/rust-api:latest
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:8080"
          volumes:
            - /home/ubuntu/cloud/architecture.json:/app/config/architecture.json:ro
            - /opt/containers/rust-api/config.json:/app/config/config.json:ro
            - ~/.ssh:/home/appuser/.ssh:ro
            - /home/ubuntu/cloud/oci_config:/app/config/oci_config:ro
            - /home/ubuntu/cloud/oci_api_key.pem:/app/config/oci_api_key.pem:ro
            - /home/ubuntu/cloud/gcp_key.json:/app/config/gcp_key.json:ro
          env_file:
            - .secrets
          environment:
            - RUST_API_PORT=8080
            - RUST_LOG=rust_api=info
            - CLOUD_CONFIG_PATH=/app/config/architecture.json
            - OCI_CONFIG_FILE=/app/config/oci_config
            - OCI_KEY_FILE=/app/config/oci_api_key.pem
            - GCP_SERVICE_ACCOUNT_FILE=/app/config/gcp_key.json
            - CONFIG_JSON_PATH=/app/config/config.json
            - SSH_KEY_PATH=/home/appuser/.ssh/id_rsa
            - GCP_SSH_KEY_PATH=/home/appuser/.ssh/google_compute_engine
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8080/api/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s

    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "rust-api-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
