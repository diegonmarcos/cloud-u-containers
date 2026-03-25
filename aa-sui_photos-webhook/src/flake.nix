{
  description = "Photos Webhook - PostgreSQL + webhook processor for PhotoPrism";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      db_container = "photos-db";
      db_image = "postgres:16-alpine";
      webhook_container = "photos-webhook";
      db_name = "photos";
      db_user = "photos_user";
    };

    title = "Photos Webhook - PostgreSQL + webhook processor for PhotoPrism";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/aa-sui_photos-webhook/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/aa-sui_photos-webhook/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        photos-db:
          image: ${config.db_image}
          container_name: ${config.db_container}
          network_mode: host
          environment:
            POSTGRES_DB: ${config.db_name}
            POSTGRES_USER: ${config.db_user}
            POSTGRES_PASSWORD: ''${DB_PASSWORD:-SECURE_PASSWORD_HERE}
          volumes:
            - photos_db_data:/var/lib/postgresql/data
            - ./schema.sql:/docker-entrypoint-initdb.d/01-schema.sql
          restart: "no"  # container-init handles startup
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ${config.db_user} -d ${config.db_name}"]
            interval: 10s
            timeout: 5s
            retries: 5

        photos-webhook:
          build:
            context: .
            dockerfile: Dockerfile
          container_name: ${config.webhook_container}
          network_mode: host
          environment:
            DB_HOST: localhost
            DB_NAME: ${config.db_name}
            DB_USER: ${config.db_user}
            DB_PASSWORD: ''${DB_PASSWORD:-SECURE_PASSWORD_HERE}
            S3_ACCESS_KEY: ''${S3_ACCESS_KEY}
            S3_SECRET_KEY: ''${S3_SECRET_KEY}
            S3_REGION: eu-marseille-1
            S3_BUCKET: photos
            WEBHOOK_PORT: 5002
          depends_on:
            photos-db:
              condition: service_healthy
          volumes:
            - ./webhook.py:/app/webhook.py
            - ./requirements.txt:/app/requirements.txt
          restart: "no"  # container-init handles startup
          command: python webhook.py flask
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:5002/health"]
            interval: 10s
            timeout: 5s
            retries: 5

      volumes:
        photos_db_data:
          driver: local
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
      defaultPkg = pkgs.runCommand "photos-webhook-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./requirements.txt} $out/requirements.txt
        cp ${./webhook.py} $out/webhook.py
        cp ${./schema.sql} $out/schema.sql
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
