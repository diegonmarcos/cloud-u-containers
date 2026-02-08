{
  description = "C3 Collector - Metrics/Logs Collection Agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "c3-collector";
      image = "grafana/alloy:latest";  # Or vector/fluentbit depending on actual setup
      port = 4317;  # OTLP gRPC
      http_port = 4318;  # OTLP HTTP
      timezone = "Europe/Madrid";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      

      services:
        c3-collector:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
          ports:
            - "${toString config.port}:4317"
            - "${toString config.http_port}:4318"
          volumes:
            - ./config:/etc/alloy
            - ./data:/var/lib/alloy
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

    # Alloy configuration for collecting metrics
    mkAlloyConfig = pkgs: pkgs.writeText "config.alloy" ''
      // C3 Collector Configuration

      logging {
        level = "info"
      }

      // Prometheus metrics scraping
      prometheus.scrape "containers" {
        targets = [
          {"__address__" = "host.docker.internal:9090"},
        ]
        forward_to = [prometheus.remote_write.central.receiver]
      }

      // Remote write to central
      prometheus.remote_write "central" {
        endpoint {
          url = "http://syslog-central:9090/api/v1/write"
        }
      }
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "c3-collector-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
