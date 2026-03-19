{
  description = "db-agent - Central database backup service (all VMs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "db-agent";
    };

    title = "db-agent - Central database backup service (all VMs)";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ca-dat_db-agent/src/flake.nix   ║
      # ║ Rebuild: ~/git/cloud/a_solutions/ca-dat_db-agent/build.sh ship  ║
      # ╚══════════════════════════════════════════════════════════════════╝
      # db-agent - Central database backup service
      # Deploy to: ALL VMs
      # Runs daily, auto-detects databases, dumps + logs

      services:
        db-agent:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          mem_limit: 64m
          cpus: 0.1
          environment:
            - VM_NAME=''${VM_NAME:-unknown}
            - SCHEDULE=''${SCHEDULE:-0 3 * * *}
            - NTFY_URL=''${NTFY_URL:-http://ntfy:80}
            - NTFY_TOPIC=''${NTFY_TOPIC:-backup}
            - RETENTION_DAYS=''${RETENTION_DAYS:-7}
            - BUP_REMOTE=''${BUP_REMOTE:-}
            - TZ=UTC
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - db-agent-data:/backup
            - db-agent-logs:/var/log/db-agent
          networks:
            infra:
              ipv4_address: 172.23.0.15
          dns:
            - 172.23.0.2
          healthcheck:
            test: ["CMD", "test", "-f", "/var/log/db-agent/last-run.json"]
            interval: 60s
            timeout: 5s
            retries: 3
            start_period: 120s
          logging:
            driver: "json-file"
            options:
              max-size: "5m"
              max-file: "3"

      volumes:
        db-agent-data:
          name: db-agent-data
        db-agent-logs:
          name: db-agent-logs

      networks:
        infra:
          external: true
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
      defaultPkg = pkgs.runCommand "db-agent-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./entrypoint.sh} $out/entrypoint.sh
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
