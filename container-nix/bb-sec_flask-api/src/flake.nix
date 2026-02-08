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
          build: ./c3-collector
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
        mkdir -p $out/app/api $out/app/data $out/app/models $out/app/utils
        mkdir -p $out/c3-collector/1.collectors $out/c3-collector/3.converters
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./requirements.txt} $out/requirements.txt
        cp ${./run.py} $out/run.py
        # Flask app
        cp ${./app/__init__.py} $out/app/__init__.py
        cp ${./app/config.py} $out/app/config.py
        cp ${./app/api/__init__.py} $out/app/api/__init__.py
        cp ${./app/api/admin.py} $out/app/api/admin.py
        cp ${./app/api/alerts.py} $out/app/api/alerts.py
        cp ${./app/api/auth.py} $out/app/api/auth.py
        cp ${./app/api/c3.py} $out/app/api/c3.py
        cp ${./app/api/routes.py} $out/app/api/routes.py
        cp ${./app/api/web.py} $out/app/api/web.py
        cp ${./app/data/cloud_architecture.json} $out/app/data/cloud_architecture.json
        cp ${./app/data/cloud_control.json} $out/app/data/cloud_control.json
        cp ${./app/models/__init__.py} $out/app/models/__init__.py
        cp ${./app/utils/__init__.py} $out/app/utils/__init__.py
        cp ${./app/utils/health.py} $out/app/utils/health.py
        # C3 collector
        cp ${./c3-collector/Dockerfile} $out/c3-collector/Dockerfile
        cp ${./c3-collector/main.py} $out/c3-collector/main.py
        cp ${./c3-collector/1.collectors/config.py} $out/c3-collector/1.collectors/config.py
        cp ${./c3-collector/1.collectors/0.architecture.py} $out/c3-collector/1.collectors/0.architecture.py
        cp ${./c3-collector/1.collectors/0.docker.py} $out/c3-collector/1.collectors/0.docker.py
        cp ${./c3-collector/1.collectors/1.availability.py} $out/c3-collector/1.collectors/1.availability.py
        cp ${./c3-collector/1.collectors/1.performance.py} $out/c3-collector/1.collectors/1.performance.py
        cp ${./c3-collector/1.collectors/2.backups.py} $out/c3-collector/1.collectors/2.backups.py
        cp ${./c3-collector/1.collectors/2.security.py} $out/c3-collector/1.collectors/2.security.py
        cp ${./c3-collector/1.collectors/2.web.py} $out/c3-collector/1.collectors/2.web.py
        cp ${./c3-collector/1.collectors/3.cost_ai.py} $out/c3-collector/1.collectors/3.cost_ai.py
        cp ${./c3-collector/1.collectors/3.cost_infra.py} $out/c3-collector/1.collectors/3.cost_infra.py
        cp ${./c3-collector/3.converters/to_csv.py} $out/c3-collector/3.converters/to_csv.py
        cp ${./c3-collector/3.converters/to_json.py} $out/c3-collector/3.converters/to_json.py
        cp ${./c3-collector/3.converters/to_js.py} $out/c3-collector/3.converters/to_js.py
        cp ${./c3-collector/3.converters/to_markdown.py} $out/c3-collector/3.converters/to_markdown.py
      '';
    });
  };
}
