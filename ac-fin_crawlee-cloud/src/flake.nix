{
  description = "Crawlee Cloud - Self-hosted Apify-compatible scraping platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    crawlee-src = {
      url = "github:crawlee-cloud/crawlee-cloud";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crawlee-src }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      api_port = 3000;
      dashboard_port = 3001;
      minio_port = 9000;
      minio_console_port = 9001;
      db_port = 5433;       # avoid conflict with quant-lab's 5432
      redis_port = 6380;    # avoid conflict with other redis instances
    };

    title = "Crawlee Cloud - Self-hosted Apify-compatible scraping platform";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        # ═══ CORE (built from source) ═══

        api:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.api
          image: crawlee-cloud-api:local
          container_name: crawlee_api
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            NODE_ENV: production
            PORT: "3000"
            DATABASE_URL: postgresql://''${POSTGRES_USER}:''${POSTGRES_PASSWORD}@crawlee_db:5432/''${POSTGRES_DB}
            REDIS_URL: redis://crawlee_redis:6379
            S3_ENDPOINT: http://crawlee_minio:9000
            S3_ACCESS_KEY: ''${MINIO_USER}
            S3_SECRET_KEY: ''${MINIO_PASSWORD}
            S3_BUCKET: crawlee-cloud
            S3_FORCE_PATH_STYLE: "true"
            JWT_SECRET: ''${JWT_SECRET}
            RATE_LIMIT_MAX: "1000"
            LOG_LEVEL: info
            ADMIN_EMAIL: ''${ADMIN_EMAIL}
            ADMIN_PASSWORD: ''${ADMIN_PASSWORD}
          ports:
            - "${toString config.api_port}:3000"
          depends_on:
            crawlee_db:
              condition: service_healthy
            crawlee_redis:
              condition: service_healthy
            crawlee_minio:
              condition: service_healthy
          networks:
            - crawlee_network
          healthcheck:
            test: ["CMD-SHELL", "wget -q --spider http://localhost:3000/health || exit 1"]
            interval: 15s
            timeout: 5s
            retries: 3
            start_period: 20s

        runner:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.runner
          image: crawlee-cloud-runner:local
          container_name: crawlee_runner
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            NODE_ENV: production
            API_BASE_URL: http://crawlee_api:3000
            API_TOKEN: ''${RUNNER_TOKEN}
            DATABASE_URL: postgresql://''${POSTGRES_USER}:''${POSTGRES_PASSWORD}@crawlee_db:5432/''${POSTGRES_DB}
            REDIS_URL: redis://crawlee_redis:6379
            DOCKER_SOCKET: /var/run/docker.sock
            DOCKER_NETWORK: crawlee_network
            MAX_CONCURRENT_RUNS: "5"
            ACTOR_MAX_MEMORY_MB: "2048"
            ACTOR_DEFAULT_MEMORY_MB: "512"
            ACTOR_TIMEOUT_SECS: "3600"
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock
          depends_on:
            api:
              condition: service_healthy
          networks:
            - crawlee_network

        dashboard:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.dashboard
          image: crawlee-cloud-dashboard:local
          container_name: crawlee_dashboard
          restart: unless-stopped
          environment:
            NODE_ENV: production
            PORT: "3001"
            NEXT_PUBLIC_API_URL: http://crawlee_api:3000
          ports:
            - "${toString config.dashboard_port}:3001"
          depends_on:
            api:
              condition: service_healthy
          networks:
            - crawlee_network

        scheduler:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.api
          image: crawlee-cloud-api:local
          container_name: crawlee_scheduler
          restart: unless-stopped
          env_file:
            - .secrets
          command: ["node", "packages/api/dist/scheduler.js"]
          environment:
            NODE_ENV: production
            DATABASE_URL: postgresql://''${POSTGRES_USER}:''${POSTGRES_PASSWORD}@crawlee_db:5432/''${POSTGRES_DB}
            REDIS_URL: redis://crawlee_redis:6379
          depends_on:
            api:
              condition: service_healthy
          networks:
            - crawlee_network

        # ═══ DATA STORES (standard images) ═══

        crawlee_db:
          image: postgres:16-alpine
          container_name: crawlee_db
          restart: unless-stopped
          env_file:
            - .secrets
          environment:
            POSTGRES_USER: ''${POSTGRES_USER}
            POSTGRES_PASSWORD: ''${POSTGRES_PASSWORD}
            POSTGRES_DB: ''${POSTGRES_DB}
          ports:
            - "${toString config.db_port}:5432"
          volumes:
            - crawlee_postgres:/var/lib/postgresql/data
          networks:
            - crawlee_network
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ''${POSTGRES_USER}"]
            interval: 5s
            timeout: 5s
            retries: 5

        crawlee_redis:
          image: redis:7-alpine
          container_name: crawlee_redis
          restart: unless-stopped
          command: redis-server --appendonly yes
          ports:
            - "${toString config.redis_port}:6379"
          volumes:
            - crawlee_redis:/data
          networks:
            - crawlee_network
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 5s
            timeout: 5s
            retries: 5

        crawlee_minio:
          image: minio/minio:latest
          container_name: crawlee_minio
          restart: unless-stopped
          command: server /data --console-address ":9001"
          env_file:
            - .secrets
          environment:
            MINIO_ROOT_USER: ''${MINIO_USER}
            MINIO_ROOT_PASSWORD: ''${MINIO_PASSWORD}
          ports:
            - "${toString config.minio_port}:9000"
            - "${toString config.minio_console_port}:9001"
          volumes:
            - crawlee_minio:/data
          networks:
            - crawlee_network
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
            interval: 5s
            timeout: 5s
            retries: 5

        minio_init:
          image: minio/mc:latest
          container_name: crawlee_minio_init
          depends_on:
            crawlee_minio:
              condition: service_healthy
          env_file:
            - .secrets
          entrypoint: >
            /bin/sh -c "
            mc alias set myminio http://crawlee_minio:9000 ''${MINIO_USER} ''${MINIO_PASSWORD};
            mc mb myminio/crawlee-cloud --ignore-existing;
            exit 0;
            "
          networks:
            - crawlee_network

      volumes:
        crawlee_postgres:
          name: crawlee_postgres
        crawlee_redis:
          name: crawlee_redis
        crawlee_minio:
          name: crawlee_minio

      networks:
        crawlee_network:
          name: crawlee_network
          driver: bridge
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
      defaultPkg = pkgs.runCommand "crawlee-cloud-configs" {} ''
        mkdir -p $out/repo
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp -r ${crawlee-src}/. $out/repo/
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
