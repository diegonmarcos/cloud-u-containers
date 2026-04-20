{
  description = "LGTM Stack - Grafana Labs Observability (Loki, Grafana, Tempo, Mimir)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    # Support both architectures (output is text-only)
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };
    svc = (builtins.fromJSON (builtins.readFile ./cloud-data-service-connections.json)).services;
    # Per-container build.*.json symlinks (source of truth for container_name + image)
    cGrafana = (builtins.fromJSON (builtins.readFile ./build-lgtm_grafana.json)).container;
    cLoki    = (builtins.fromJSON (builtins.readFile ./build-lgtm_loki.json)).container;
    cTempo   = (builtins.fromJSON (builtins.readFile ./build-lgtm_tempo.json)).container;
    cMimir   = (builtins.fromJSON (builtins.readFile ./build-lgtm_mimir.json)).container;

    # GHCR images: wrap public images with OCI label for GHCR
    ghcrGrafana = docker.mkGhcrBuild {
      name = "lgtm-grafana";
      fromImage = cGrafana.image;
    };
    ghcrLoki = docker.mkGhcrBuild {
      name = "lgtm-loki";
      fromImage = cLoki.image;
    };
    ghcrTempo = docker.mkGhcrBuild {
      name = "lgtm-tempo";
      fromImage = cTempo.image;
      configFiles = [ { src = "config/tempo.yaml"; dst = "/etc/tempo/tempo.yaml"; } ];
    };
    ghcrMimir = docker.mkGhcrBuild {
      name = "lgtm-mimir";
      fromImage = cMimir.image;
      configFiles = [ { src = "config/mimir.yaml"; dst = "/etc/mimir/mimir.yaml"; } ];
    };

    config = {
      domain = buildJson.domain;
      grafana_port = ports.valueOf "grafana";
      loki_port = ports.valueOf "loki";
      mimir_port = ports.valueOf "mimir";
      tempo_port = ports.valueOf "tempo";
      grafana_container = cGrafana.container_name;
      loki_container = cLoki.container_name;
      tempo_container = cTempo.container_name;
      mimir_container = cMimir.container_name;
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
          image: ${ghcrGrafana.image}
          build:
            context: ${ghcrGrafana.build.context}
            dockerfile_inline: |
              ${builtins.replaceStrings ["\n"] ["\n        "] ghcrGrafana.build.dockerfile_inline}
          container_name: ${config.grafana_container}
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - grafana_data:/var/lib/grafana
          environment:
            - GF_SECURITY_ADMIN_USER=admin
            - GF_SECURITY_ADMIN_PASSWORD=''${GRAFANA_ADMIN_PASSWORD:-changeme}
            - GF_USERS_ALLOW_SIGN_UP=false
            - GF_SERVER_HTTP_PORT=${toString config.grafana_port}
            - GF_SERVER_ROOT_URL=https://${config.domain}
          depends_on:
            - loki
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:${toString config.grafana_port}/api/health']
            interval: 30s
            timeout: 10s
            retries: 3

        loki:
          image: ${ghcrLoki.image}
          build:
            context: ${ghcrLoki.build.context}
            dockerfile_inline: |
              ${builtins.replaceStrings ["\n"] ["\n        "] ghcrLoki.build.dockerfile_inline}
          container_name: ${config.loki_container}
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - loki_data:/loki
            - /home/ubuntu/bin/busybox-static:/usr/local/bin/busybox:ro
          command: -config.file=/etc/loki/local-config.yaml -server.http-listen-address=${svc.lgtm.ip} -server.http-listen-port=${toString config.loki_port} -server.grpc-listen-port=9111
          healthcheck:
            test: ['CMD', '/usr/local/bin/busybox', 'wget', '-qO', '/dev/null', 'http://127.0.0.1:${toString config.loki_port}/ready']
            interval: 30s
            timeout: 10s
            retries: 5
            start_period: 120s

        tempo:
          image: ${ghcrTempo.image}
          build:
            context: ${ghcrTempo.build.context}
            dockerfile_inline: |
              ${builtins.replaceStrings ["\n"] ["\n        "] ghcrTempo.build.dockerfile_inline}
          container_name: ${config.tempo_container}
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - tempo_data:/var/tempo
          command: ["-config.file=/etc/tempo/tempo.yaml"]

        mimir:
          image: ${ghcrMimir.image}
          build:
            context: ${ghcrMimir.build.context}
            dockerfile_inline: |
              ${builtins.replaceStrings ["\n"] ["\n        "] ghcrMimir.build.dockerfile_inline}
          container_name: ${config.mimir_container}
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - mimir_data:/data
          command: ["-config.file=/etc/mimir/mimir.yaml", "-target=all"]

      volumes:
        grafana_data:
        loki_data:
        tempo_data:
        mimir_data:
    '';

    # ── Config: Tempo ──────────────────────────────────────────────────
    mkTempoConfig = pkgs: pkgs.writeText "tempo.yaml" ''
      server:
        http_listen_port: ${toString config.tempo_port}
        grpc_listen_port: 9112

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
        http_listen_port: ${toString config.mimir_port}
        grpc_listen_port: 9113

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
          url: http://localhost:${toString config.loki_port}
          isDefault: true

        - name: Tempo
          type: tempo
          access: proxy
          url: http://localhost:${toString config.tempo_port}

        - name: Mimir
          type: prometheus
          access: proxy
          url: http://localhost:${toString config.mimir_port}/prometheus

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
          url: ${svc.matomo.ip}:${toString svc.matomo.ports.db}
          database: matomo
          user: matomo
          secureJsonData:
            password: <REDACTED-LEAK-2026-04-21>

        - name: NPM SQLite (Postlite)
          type: postgres
          access: proxy
          url: ${svc.postlite.ip}:${toString svc.postlite.ports.npm_pg}
          database: database
          user: any
          secureJsonData:
            password: any
          jsonData:
            sslmode: disable

        - name: Vaultwarden SQLite (Postlite)
          type: postgres
          access: proxy
          url: ${svc.postlite.ip}:${toString svc.postlite.ports.vaultwarden_pg}
          database: db
          user: any
          secureJsonData:
            password: any
          jsonData:
            sslmode: disable

        - name: ntfy SQLite (Postlite)
          type: postgres
          access: proxy
          url: ${svc.postlite.ip}:${toString svc.postlite.ports.ntfy_pg}
          database: cache
          user: any
          secureJsonData:
            password: any
          jsonData:
            sslmode: disable

        - name: Authelia SQLite (Postlite)
          type: postgres
          access: proxy
          url: ${svc.postlite.ip}:${toString svc.postlite.ports.authelia_pg}
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
