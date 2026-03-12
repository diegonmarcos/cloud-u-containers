{
  description = "Windmill - Workflow orchestration platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "windmill.diegonmarcos.com";
    };

    title = "Windmill - Workflow orchestration platform";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Windmill Workflow Orchestration Platform
      # Deploy on: oci-A1-f_0 (oci-apps, 10.0.0.6)
      # Port: 8000 (internal, proxied via Caddy)

      services:
        windmill-db:
          image: postgres:16-alpine
          container_name: windmill-db
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            - POSTGRES_DB=windmill
            - POSTGRES_USER=windmill
            - POSTGRES_PASSWORD=''${DB_PASSWORD}
          volumes:
            - windmill-db-data:/var/lib/postgresql/data
          networks:
            - windmill-net
          deploy:
            resources:
              limits:
                memory: 128M
              reservations:
                memory: 64M
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U windmill -d windmill"]
            interval: 10s
            timeout: 5s
            retries: 5

        windmill-server:
          image: ghcr.io/windmill-labs/windmill:main
          container_name: windmill-server
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            - DATABASE_URL=postgres://windmill:''${DB_PASSWORD}@windmill-db:5432/windmill?sslmode=disable
            - MODE=server
            - BASE_URL=https://${config.domain}
            - COOKIE_DOMAIN=diegonmarcos.com
            - NUM_WORKERS=2
            - DISABLE_NUSER=true
            - METRICS_ENABLED=false
            - OAUTH_CLIENT_ID=''${OAUTH_CLIENT_ID:-}
            - OAUTH_CLIENT_SECRET=''${OAUTH_CLIENT_SECRET:-}
            - SMTP_HOST=''${SMTP_HOST:-}
            - SMTP_PORT=''${SMTP_PORT:-}
            - SMTP_FROM=''${SMTP_FROM:-}
            - SMTP_USERNAME=''${SMTP_USERNAME:-}
            - SMTP_PASSWORD=''${SMTP_PASSWORD:-}
          ports:
            - "10.0.0.6:8000:8000"
          depends_on:
            windmill-db:
              condition: service_healthy
          volumes:
            - windmill-server-data:/tmp/windmill
            - /var/run/docker.sock:/var/run/docker.sock
          networks:
            - windmill-net
          deploy:
            resources:
              limits:
                memory: 256M
                cpus: '0.5'
              reservations:
                memory: 128M
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8000/api/version"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 30s

        windmill-worker:
          image: ghcr.io/windmill-labs/windmill:main
          container_name: windmill-worker
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            - DATABASE_URL=postgres://windmill:''${DB_PASSWORD}@windmill-db:5432/windmill?sslmode=disable
            - MODE=worker
            - WORKER_GROUP=default
            - NUM_WORKERS=2
            - DISABLE_NUSER=true
            - KEEP_JOB_DIR=false
            - METRICS_ENABLED=false
          depends_on:
            windmill-server:
              condition: service_healthy
          volumes:
            - windmill-worker-data:/tmp/windmill
            - /var/run/docker.sock:/var/run/docker.sock
            - ~/.ssh:/home/windmill/.ssh:ro
          networks:
            - windmill-net
          deploy:
            resources:
              limits:
                memory: 256M
                cpus: '0.5'
              reservations:
                memory: 128M

      networks:
        windmill-net:
          name: windmill-net
          driver: bridge

      volumes:
        windmill-db-data:
          name: windmill-db-data
        windmill-server-data:
          name: windmill-server-data
        windmill-worker-data:
          name: windmill-worker-data

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
      defaultPkg = pkgs.runCommand "windmill-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
