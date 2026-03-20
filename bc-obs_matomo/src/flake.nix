{
  description = "Matomo Analytics (Hybrid Container) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "analytics.diegonmarcos.com";
      container_name = "matomo-hybrid";
      port = 8080;
    };

    title = "Matomo Analytics (Hybrid Container)";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_matomo/src/flake.nix     ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_matomo/build.sh ship    ║
      # ╚══════════════════════════════════════════════════════════════════╝
      # Matomo Hybrid Container
      # VM: oci-E2-f_1 (129.151.228.66)
      # Domain: ${config.domain}
      #
      # Single container with:
      #   - Always-on: receiver-nginx + receiver-php-fpm (~30-50MB RAM)
      #   - On-demand: mariadb + matomo-php-fpm + matomo-nginx (~500-700MB RAM)
      #
      # Usage:
      #   docker compose up -d                                    # Start (receiver only)
      #   docker exec matomo-hybrid /scripts/matomo-wake.sh       # Wake full Matomo
      #   docker exec matomo-hybrid /scripts/matomo-sleep.sh      # Sleep Matomo

      services:
        matomo-hybrid:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "10.0.0.4:${toString config.port}:8080"
          volumes:
            - matomo_matomo_data:/var/www/html
            - matomo_matomo_db:/var/lib/mysql
            - matomo_inbox:/inbox
          environment:
            - MATOMO_DATABASE_HOST=localhost
            - MATOMO_DATABASE_USERNAME=''${MATOMO_DB_USER:-matomo}
            - MATOMO_DATABASE_PASSWORD=''${MATOMO_DB_PASSWORD:-<REDACTED-LEAK-2026-04-21>}
            - MATOMO_DATABASE_DBNAME=''${MATOMO_DB_NAME:-matomo}
            - MATOMO_API_TOKEN=''${MATOMO_API_TOKEN}
          deploy:
            resources:
              limits:
                memory: 1024M
              reservations:
                memory: 64M

      volumes:
        matomo_matomo_data:
          name: matomo_matomo_data
        matomo_matomo_db:
          name: matomo_matomo_db
        matomo_inbox:
          name: matomo_inbox
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
      defaultPkg = pkgs.runCommand "matomo-configs" {} ''
        mkdir -p $out/config $out/manage $out/receiver $out/scripts
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./matomo-hybrid/Dockerfile} $out/Dockerfile
        # Config files
        cp ${./matomo-hybrid/config/mariadb.cnf} $out/config/mariadb.cnf
        cp ${./matomo-hybrid/config/matomo-fpm.conf} $out/config/matomo-fpm.conf
        cp ${./matomo-hybrid/config/matomo-nginx.conf} $out/config/matomo-nginx.conf
        cp ${./matomo-hybrid/config/receiver-fpm.conf} $out/config/receiver-fpm.conf
        cp ${./matomo-hybrid/config/receiver-nginx.conf} $out/config/receiver-nginx.conf
        cp ${./matomo-hybrid/config/supervisord.conf} $out/config/supervisord.conf
        # Scripts
        cp ${./matomo-hybrid/scripts/entrypoint.sh} $out/scripts/entrypoint.sh
        cp ${./matomo-hybrid/scripts/import-inbox.sh} $out/scripts/import-inbox.sh
        cp ${./matomo-hybrid/scripts/matomo-sleep.sh} $out/scripts/matomo-sleep.sh
        cp ${./matomo-hybrid/scripts/matomo-wake.sh} $out/scripts/matomo-wake.sh
        cp ${./matomo-hybrid/scripts/matomo-archiver.sh} $out/scripts/matomo-archiver.sh
        # Management & receiver
        cp ${./matomo-hybrid/manage/matomo-manage.sh} $out/manage/matomo-manage.sh
        cp ${./matomo-hybrid/receiver/receive.php} $out/receiver/receive.php
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
