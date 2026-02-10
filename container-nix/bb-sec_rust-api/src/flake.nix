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
            - /home/diego/cloud/architecture.json:/app/config/architecture.json:ro
            - ~/.ssh:/home/appuser/.ssh:ro
            - /home/diego/cloud/oci_config:/app/config/oci_config:ro
            - /home/diego/cloud/oci_api_key.pem:/app/config/oci_api_key.pem:ro
            - /home/diego/cloud/gcp_key.json:/app/config/gcp_key.json:ro
          environment:
            - RUST_API_PORT=8080
            - RUST_LOG=rust_api=info
            - CLOUD_CONFIG_PATH=/app/config/architecture.json
            - OCI_CONFIG_FILE=/app/config/oci_config
            - OCI_KEY_FILE=/app/config/oci_api_key.pem
            - OCI_FLEX1_INSTANCE_ID=''${OCI_FLEX1_INSTANCE_ID}
            - OCI_MICRO1_INSTANCE_ID=''${OCI_MICRO1_INSTANCE_ID}
            - OCI_MICRO2_INSTANCE_ID=''${OCI_MICRO2_INSTANCE_ID}
            - GCP_SERVICE_ACCOUNT_FILE=/app/config/gcp_key.json
            - GCP_PROJECT_ID=''${GCP_PROJECT_ID}
            - SSH_KEY_PATH=/home/appuser/.ssh/id_rsa
            - GCP_SSH_KEY_PATH=/home/appuser/.ssh/google_compute_engine
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
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
