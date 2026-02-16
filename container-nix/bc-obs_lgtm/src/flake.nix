{
  description = "LGTM Stack - Grafana Labs Observability (Loki, Grafana, Tempo, Mimir)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    # Support both architectures (output is text-only)
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "grafana.diegonmarcos.com";
    };

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # LGTM Stack - Grafana Labs Observability
      # Deployed on: oci-A1-f_1 (Oracle Flex)
      services:
        grafana:
          image: grafana/grafana:latest
          container_name: lgtm_grafana
          restart: unless-stopped
          ports:
            - "10.0.0.2:3016:3000"
          volumes:
            - grafana_data:/var/lib/grafana
          environment:
            - GF_SECURITY_ADMIN_USER=admin
            - GF_SECURITY_ADMIN_PASSWORD=''${GRAFANA_ADMIN_PASSWORD:-changeme}
            - GF_USERS_ALLOW_SIGN_UP=false
            - GF_SERVER_ROOT_URL=https://${config.domain}
          depends_on:
            - loki
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:3000/api/health']
            interval: 30s
            timeout: 10s
            retries: 3

        loki:
          image: grafana/loki:latest
          container_name: lgtm_loki
          restart: unless-stopped
          ports:
            - "10.0.0.2:3017:3100"
          volumes:
            - loki_data:/loki
          command: -config.file=/etc/loki/local-config.yaml
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:3100/ready']
            interval: 30s
            timeout: 10s
            retries: 3

        tempo:
          image: grafana/tempo:latest
          container_name: lgtm_tempo
          restart: unless-stopped
          ports:
            - "10.0.0.2:3018:3200"
            - "10.0.0.2:4317:4317"
            - "10.0.0.2:4318:4318"
          volumes:
            - tempo_data:/var/tempo
            - ./config/tempo.yaml:/etc/tempo/tempo.yaml:ro
          command: ["-config.file=/etc/tempo/tempo.yaml"]
          networks:
            - dev_network

        mimir:
          image: grafana/mimir:latest
          container_name: lgtm_mimir
          restart: unless-stopped
          ports:
            - "10.0.0.2:3019:8080"
          volumes:
            - mimir_data:/data
            - ./config/mimir.yaml:/etc/mimir/mimir.yaml:ro
          command: ["-config.file=/etc/mimir/mimir.yaml", "-target=all"]
          networks:
            - dev_network

      networks:
        dev_network:
          external: true
          name: dev_network

      volumes:
        grafana_data:
        loki_data:
        tempo_data:
        mimir_data:
    '';

    # ── Config: Tempo ──────────────────────────────────────────────────
    mkTempoConfig = pkgs: pkgs.writeText "tempo.yaml" ''
      server:
        http_listen_port: 3200

      distributor:
        receivers:
          otlp:
            protocols:
              grpc:
              http:

      storage:
        trace:
          backend: local
          local:
            path: /var/tempo/traces
          wal:
            path: /var/tempo/wal
    '';

    # ── Config: Mimir ──────────────────────────────────────────────────
    mkMimirConfig = pkgs: pkgs.writeText "mimir.yaml" ''
      multitenancy_enabled: false

      blocks_storage:
        backend: filesystem
        filesystem:
          dir: /data/blocks

      server:
        http_listen_port: 8080

      distributor:
        ring:
          kvstore:
            store: inmemory

      ingester:
        ring:
          kvstore:
            store: inmemory
          replication_factor: 1

      store_gateway:
        sharding_ring:
          replication_factor: 1

      compactor:
        sharding_ring:
          kvstore:
            store: inmemory
    '';

    # ── Config: Grafana Datasources ────────────────────────────────────
    mkDatasources = pkgs: pkgs.writeText "datasources.yml" ''
      apiVersion: 1

      datasources:
        - name: Loki
          type: loki
          access: proxy
          url: http://lgtm_loki:3100
          isDefault: true

        - name: Tempo
          type: tempo
          access: proxy
          url: http://lgtm_tempo:3200

        - name: Mimir
          type: prometheus
          access: proxy
          url: http://lgtm_mimir:8080/prometheus

        - name: Photoprism MariaDB
          type: mysql
          access: proxy
          url: photoprism-db:3306
          database: photoprism
          user: photoprism
          secureJsonData:
            password: photoprism_db123

        - name: Matomo MariaDB
          type: mysql
          access: proxy
          url: 10.0.0.4:3306
          database: matomo
          user: matomo
          secureJsonData:
            password: <REDACTED-LEAK-2026-04-21>

        - name: NPM SQLite (Postlite)
          type: postgres
          access: proxy
          url: 10.0.0.1:5433
          database: database
          user: any
          secureJsonData:
            password: any
          jsonData:
            sslmode: disable

        - name: Vaultwarden SQLite (Postlite)
          type: postgres
          access: proxy
          url: 10.0.0.1:5434
          database: db
          user: any
          secureJsonData:
            password: any
          jsonData:
            sslmode: disable

        - name: ntfy SQLite (Postlite)
          type: postgres
          access: proxy
          url: 10.0.0.1:5435
          database: cache
          user: any
          secureJsonData:
            password: any
          jsonData:
            sslmode: disable

        - name: Authelia SQLite (Postlite)
          type: postgres
          access: proxy
          url: 10.0.0.1:5436
          database: db
          user: any
          secureJsonData:
            password: any
          jsonData:
            sslmode: disable
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "lgtm-configs" {} ''
        mkdir -p $out/config
        mkdir -p $out/provisioning/datasources
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkTempoConfig pkgs}   $out/config/tempo.yaml
        cp ${mkMimirConfig pkgs}   $out/config/mimir.yaml
        cp ${mkDatasources pkgs}   $out/provisioning/datasources/datasources.yml
      '';
    });
  };
}
