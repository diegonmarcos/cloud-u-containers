{
  description = "Cloud API (Flask) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "api.diegonmarcos.com";
      container_name = "flask-api";
      port = 5000;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        flask-api:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:5000"
          volumes:
            - c3-data:/app/c3-data:ro
            - /home/diego/cloud/architecture.json:/app/config/architecture.json:ro
            - ~/.ssh:/home/appuser/.ssh:ro
            - /home/diego/cloud/oci_config:/app/config/oci_config:ro
            - /home/diego/cloud/oci_api_key.pem:/app/config/oci_api_key.pem:ro
          environment:
            - FLASK_DEBUG=false
            - CLOUD_CONFIG_PATH=/app/config/architecture.json
            - OCI_CONFIG_FILE=/app/config/oci_config
            - OCI_KEY_FILE=/app/config/oci_api_key.pem
            - OCI_WAKE_INSTANCE_ID=''${OCI_WAKE_INSTANCE_ID}
            - NTFY_URL=http://ntfy:80
            - NTFY_TOKEN=''${NTFY_TOKEN}
          networks:
            - npm_default
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:5000/api/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s
          depends_on:
            - c3-collector

        c3-collector:
          build: ../c3/in-house
          container_name: c3-collector
          restart: unless-stopped
          volumes:
            - c3-data:/app/4.jsons
            - c3-raw:/app/2.raw
            - ~/.ssh:/root/.ssh:ro
            - /home/diego/cloud/architecture.json:/app/config/architecture.json:ro
          environment:
            - TZ=UTC
          networks:
            - npm_default

      volumes:
        c3-data:
          name: c3-data
        c3-raw:
          name: c3-raw

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "flask-api-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
