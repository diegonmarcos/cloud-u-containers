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

    title = "LGTM Stack - Grafana Labs Observability (Loki, Grafana, Tempo, Mimir)";

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_lgtm/src/flake.nix       ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_lgtm/build.sh ship      ║
      # ╚══════════════════════════════════════════════════════════════════╝
      # LGTM Stack - Grafana Labs Observability
      # Deployed on: oci-A1-f_0 (Oracle Flex — consolidated)
      services:
        grafana:
          image: grafana/grafana:latest
          container_name: lgtm_grafana
          restart: unless-stopped
          ports:
            - "10.0.0.6:3016:3000"
          volumes:
            - grafana_data:/var/lib/grafana
          environment:
            - GF_SECURITY_ADMIN_USER=admin
            - GF_SECURITY_ADMIN_PASSWORD=''${GRAFANA_ADMIN_PASSWORD:-changeme}
            - GF_USERS_ALLOW_SIGN_UP=false
            - GF_SERVER_ROOT_URL=https://${config.domain}
          depends_on:
            - loki
          dns:
            - 172.21.0.2
          networks:
            infra:
              ipv4_address: 172.21.0.40
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
            - "10.0.0.6:3019:3100"
          volumes:
            - loki_data:/loki
            - /home/ubuntu/bin/busybox-static:/usr/local/bin/busybox:ro
          command: -config.file=/etc/loki/local-config.yaml
          dns:
            - 172.21.0.2
          networks:
            infra:
              ipv4_address: 172.21.0.41
          healthcheck:
            test: ['CMD', '/usr/local/bin/busybox', 'wget', '-qO', '/dev/null', 'http://127.0.0.1:3100/ready']
            interval: 30s
            timeout: 10s
            retries: 5
            start_period: 120s

        tempo:
          image: grafana/tempo:latest
          container_name: lgtm_tempo
          restart: unless-stopped
          ports:
            - "10.0.0.6:3020:3200"
            - "10.0.0.6:4317:4317"
            - "10.0.0.6:4318:4318"
          volumes:
            - tempo_data:/var/tempo
            - ./config/tempo.yaml:/etc/tempo/tempo.yaml:ro
          command: ["-config.file=/etc/tempo/tempo.yaml"]
          dns:
            - 172.21.0.2
          networks:
            infra:
              ipv4_address: 172.21.0.43

        mimir:
          image: grafana/mimir:latest
          container_name: lgtm_mimir
          restart: unless-stopped
          ports:
            - "10.0.0.6:3021:8080"
          volumes:
            - mimir_data:/data
            - ./config/mimir.yaml:/etc/mimir/mimir.yaml:ro
          command: ["-config.file=/etc/mimir/mimir.yaml", "-target=all"]
          dns:
            - 172.21.0.2
          networks:
            infra:
              ipv4_address: 172.21.0.42

      networks:
        infra:
          external: true

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


    # ── Documentation ────────────────────────────────────────────────────
    mkDocs = pkgs: defaultPkg: let
      inherit (pkgs.lib) concatMapStrings hasSuffix optionalString filter subtractLists removeSuffix;
      inherit (builtins) attrNames readDir pathExists;

      portKeys = filter (k: hasSuffix "_port" k || k == "port") (attrNames config);
      imageKeys = filter (k: hasSuffix "_image" k || k == "image") (attrNames config);
      containerKeys = filter (k: hasSuffix "_container" k || k == "container_name") (attrNames config);
      domainKeys = filter (k: k == "domain" || k == "base_domain") (attrNames config);
      otherKeys = subtractLists (portKeys ++ imageKeys ++ containerKeys ++ domainKeys) (attrNames config);

      row = k: let
        v = config.${k};
        vs = if builtins.isBool v then (if v then "true" else "false")
             else if builtins.isAttrs v || builtins.isList v then builtins.toJSON v
             else toString v;
      in "| `${k}` | `${vs}` |\n";
      section = heading: keys: optionalString (keys != []) ''
        ## ${heading}
        | Key | Value |
        |-----|-------|
        ${concatMapStrings row keys}
      '';

      hasNarrative = pathExists ./docs;
      narrativeFiles = if hasNarrative
        then filter (f: hasSuffix ".md" f) (attrNames (readDir ./docs))
        else [];

      specMd = pkgs.writeText "spec.md" ''
        # ${title}
        ${section "Network" (domainKeys ++ portKeys)}
        ${section "Containers" (containerKeys ++ imageKeys)}
        ${section "Configuration" otherKeys}
      '';

      summaryMd = pkgs.writeText "SUMMARY.md" ''
        # Summary
        - [Specification](./spec.md)
        - [Generated Configs](./configs.md)
        ${concatMapStrings (f: "- [${removeSuffix ".md" f}](./${f})\n") narrativeFiles}
      '';

      bookToml = pkgs.writeText "book.toml" ''
        [book]
        title = "${title}"
        [output.html]
        default-theme = "ayu"
      '';
    in pkgs.runCommand "docs" {
      nativeBuildInputs = [ pkgs.mdbook pkgs.file ];
    } ''
      mkdir -p build/src
      cp ${bookToml} build/book.toml
      cp ${summaryMd} build/src/SUMMARY.md
      cp ${specMd} build/src/spec.md
      ${optionalString hasNarrative "cp ${./docs}/*.md build/src/ 2>/dev/null || true"}

      # Generate configs.md from packages.default output
      echo "# Generated Configuration Files" > build/src/configs.md
      echo "" >> build/src/configs.md
      echo 'These files are produced by nix build and deployed to the VM.' >> build/src/configs.md
      echo "" >> build/src/configs.md
      find ${defaultPkg} -type f | sort | while read -r f; do
        relpath="''${f#${defaultPkg}/}"
        case "$relpath" in
          .secrets|*.secrets|*.lock|*.png|*.jpg|*.gif|*.ico|*.woff*|*.ttf|*.eot) continue ;;
        esac
        case "$relpath" in
          *.yml|*.yaml)   lang="yaml" ;;
          *.json)         lang="json" ;;
          *.toml)         lang="toml" ;;
          *.py)           lang="python" ;;
          *.sh)           lang="bash" ;;
          *.js|*.ts)      lang="javascript" ;;
          *.tf)           lang="hcl" ;;
          *.conf|*.cnf)   lang="ini" ;;
          *.html)         lang="html" ;;
          *.sql)          lang="sql" ;;
          *.zone)         lang="dns" ;;
          Dockerfile*)    lang="dockerfile" ;;
          Caddyfile*)     lang="caddy" ;;
          *)              lang="" ;;
        esac
        if file -b --mime-type "$f" | grep -q "^text/"; then
          echo '## '"$relpath" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo "~~~$lang" >> build/src/configs.md
          cat "$f" >> build/src/configs.md
          echo "" >> build/src/configs.md
          echo '~~~' >> build/src/configs.md
          echo "" >> build/src/configs.md
        fi
      done

      cd build && mdbook build -d $out
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "lgtm-configs" {} ''
        mkdir -p $out/config
        mkdir -p $out/provisioning/datasources
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkTempoConfig pkgs}   $out/config/tempo.yaml
        cp ${mkMimirConfig pkgs}   $out/config/mimir.yaml
        cp ${mkDatasources pkgs}   $out/provisioning/datasources/datasources.yml
        chmod -R a+r $out
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
