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
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    config = {
      api_port = ports.valueOf "app";
      dashboard_port = ports.valueOf "dashboard";
      minio_port = ports.valueOf "minio";
      minio_console_port = 9001;
      db_port = ports.valueOf "db";
      redis_port = ports.valueOf "redis";
    };

    title = "Crawlee Cloud - Self-hosted Apify-compatible scraping platform";
    docker = import ../../_shared/docker.nix;

    ghcr-crawlee-db = docker.mkGhcrBuild {
      name = "crawlee-db";
      fromImage = "postgres:16-alpine";
    };

    ghcr-crawlee-redis = docker.mkGhcrBuild {
      name = "crawlee-redis";
      fromImage = "redis:7-alpine";
    };

    ghcr-crawlee-minio = docker.mkGhcrBuild {
      name = "crawlee-minio";
      fromImage = "minio/minio:latest";
    };

    ghcr-crawlee-minio-mc = docker.mkGhcrBuild {
      name = "crawlee-minio-mc";
      fromImage = "minio/mc:latest";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ac-fin_crawlee-cloud/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/ac-fin_crawlee-cloud/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        # ═══ CORE (built from source) ═══

        api:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.api
          image: ghcr.io/diegonmarcos/crawlee-cloud-api:latest
          container_name: crawlee_api
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            NODE_ENV: production
            PORT: "${toString config.api_port}"
            REDIS_URL: redis://localhost:${toString config.redis_port}
            S3_ENDPOINT: http://localhost:${toString config.minio_port}
            S3_BUCKET: crawlee-cloud
            S3_FORCE_PATH_STYLE: "true"
            RATE_LIMIT_MAX: "1000"
            LOG_LEVEL: info
            DB_HOST: localhost
            DB_PORT: "${toString config.db_port}"
          command: >
            sh -c '
              export DATABASE_URL="postgresql://$$POSTGRES_USER:$$POSTGRES_PASSWORD@$$DB_HOST:$$DB_PORT/$$POSTGRES_DB"
              export S3_ACCESS_KEY="$$MINIO_USER"
              export S3_SECRET_KEY="$$MINIO_PASSWORD"
              exec node packages/api/dist/index.js
            '
          depends_on:
            crawlee_db:
              condition: service_healthy
            crawlee_redis:
              condition: service_healthy
            crawlee_minio:
              condition: service_healthy
          healthcheck:
            test: ["CMD-SHELL", "wget -qO /dev/null http://127.0.0.1:${toString config.api_port}/health || exit 1"]
            interval: 15s
            timeout: 5s
            retries: 3
            start_period: 20s

        runner:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.runner
          image: ghcr.io/diegonmarcos/crawlee-cloud-runner:latest
          container_name: crawlee_runner
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            NODE_ENV: production
            API_BASE_URL: http://localhost:${toString config.api_port}
            REDIS_URL: redis://localhost:${toString config.redis_port}
            DOCKER_SOCKET: /var/run/docker.sock
            DOCKER_NETWORK: host
            MAX_CONCURRENT_RUNS: "5"
            ACTOR_MAX_MEMORY_MB: "2048"
            ACTOR_DEFAULT_MEMORY_MB: "512"
            ACTOR_TIMEOUT_SECS: "3600"
            DB_HOST: localhost
            DB_PORT: "${toString config.db_port}"
          command: >
            sh -c '
              export DATABASE_URL="postgresql://$$POSTGRES_USER:$$POSTGRES_PASSWORD@$$DB_HOST:$$DB_PORT/$$POSTGRES_DB"
              export API_TOKEN="$$RUNNER_TOKEN"
              exec node dist/index.js
            '
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock
          depends_on:
            api:
              condition: service_healthy

        dashboard:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.dashboard
          image: ghcr.io/diegonmarcos/crawlee-cloud-dashboard:latest
          container_name: crawlee_dashboard
          restart: "no"  # container-init handles startup
          network_mode: host
          environment:
            NODE_ENV: production
            PORT: "${toString config.dashboard_port}"
            NEXT_PUBLIC_API_URL: http://localhost:${toString config.api_port}
          depends_on:
            api:
              condition: service_healthy

        scheduler:
          build:
            context: ./repo
            dockerfile: docker/Dockerfile.api
          image: ghcr.io/diegonmarcos/crawlee-cloud-api:latest
          container_name: crawlee_scheduler
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            NODE_ENV: production
            REDIS_URL: redis://localhost:${toString config.redis_port}
            DB_HOST: localhost
            DB_PORT: "${toString config.db_port}"
          command: >
            sh -c '
              export DATABASE_URL="postgresql://$$POSTGRES_USER:$$POSTGRES_PASSWORD@$$DB_HOST:$$DB_PORT/$$POSTGRES_DB"
              exec sleep infinity
            '

        # ═══ DATA STORES (standard images) ═══

        crawlee_db:
          image: ${ghcr-crawlee-db.image}
          build:
            context: .
            dockerfile_inline: |
              FROM postgres:16-alpine
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: crawlee_db
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            PGPORT: "${toString config.db_port}"
          volumes:
            - crawlee_postgres:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER"]
            interval: 5s
            timeout: 5s
            retries: 5

        crawlee_redis:
          image: ${ghcr-crawlee-redis.image}
          build:
            context: .
            dockerfile_inline: |
              FROM redis:7-alpine
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: crawlee_redis
          restart: "no"  # container-init handles startup
          network_mode: host
          command: redis-server --appendonly yes --port ${toString config.redis_port}
          volumes:
            - crawlee_redis:/data
          healthcheck:
            test: ["CMD", "redis-cli", "-p", "${toString config.redis_port}", "ping"]
            interval: 5s
            timeout: 5s
            retries: 5

        crawlee_minio:
          image: ${ghcr-crawlee-minio.image}
          build:
            context: .
            dockerfile_inline: |
              FROM minio/minio:latest
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: crawlee_minio
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          entrypoint: ["sh", "-c"]
          command:
            - 'export MINIO_ROOT_USER="$$MINIO_USER" && export MINIO_ROOT_PASSWORD="$$MINIO_PASSWORD" && exec minio server /data --address ":${toString config.minio_port}" --console-address ":${toString config.minio_console_port}"'
          volumes:
            - crawlee_minio:/data
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:${toString config.minio_port}/minio/health/live"]
            interval: 5s
            timeout: 5s
            retries: 5

        minio_init:
          image: ${ghcr-crawlee-minio-mc.image}
          build:
            context: .
            dockerfile_inline: |
              FROM minio/mc:latest
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: crawlee_minio_init
          network_mode: host
          depends_on:
            crawlee_minio:
              condition: service_healthy
          env_file:
            - .secrets
          entrypoint: >
            /bin/sh -c "
            mc alias set myminio http://localhost:${toString config.minio_port} $$MINIO_USER $$MINIO_PASSWORD;
            mc mb myminio/crawlee-cloud --ignore-existing;
            exit 0;
            "

      volumes:
        crawlee_postgres:
          name: crawlee_postgres
        crawlee_redis:
          name: crawlee_redis
        crawlee_minio:
          name: crawlee_minio

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
      defaultPkg = pkgs.runCommand "crawlee-cloud-configs" {
        nativeBuildInputs = [ pkgs.jq ];
      } ''
        mkdir -p $out/repo
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp -r ${crawlee-src}/. $out/repo/
        chmod -R u+w $out/repo

        # ── Patch: Add @fastify/swagger for OpenAPI spec generation ──

        # 1. Add swagger deps to packages/api/package.json
        jq '.dependencies["@fastify/swagger"] = "^9.4.0" | .dependencies["@fastify/swagger-ui"] = "^5.2.0"' \
          $out/repo/packages/api/package.json > $out/repo/packages/api/package.json.tmp
        mv $out/repo/packages/api/package.json.tmp $out/repo/packages/api/package.json

        # 2. Patch index.ts — add swagger imports and registration after cors
        sed -i "s|import cors from '@fastify/cors';|import cors from '@fastify/cors';\nimport swagger from '@fastify/swagger';\nimport swaggerUi from '@fastify/swagger-ui';|" \
          $out/repo/packages/api/src/index.ts

        sed -i "/await app.register(cors, { origin: true });/a\\
\\
// OpenAPI spec generation\\
await app.register(swagger, {\\
  openapi: {\\
    info: {\\
      title: 'Crawlee Cloud API',\\
      version: '1.0.0',\\
      description: 'Self-hosted Apify-compatible web scraping platform — actors, runs, datasets, key-value stores, and request queues.',\\
    },\\
    tags: [\\
      { name: 'Actors', description: 'Actor management and execution' },\\
      { name: 'Runs', description: 'Actor run status and lifecycle' },\\
      { name: 'Datasets', description: 'Crawl result datasets' },\\
      { name: 'Key-Value Stores', description: 'Key-value storage' },\\
      { name: 'Request Queues', description: 'URL queue management' },\\
      { name: 'Registry', description: 'Actor registry' },\\
      { name: 'Auth', description: 'Authentication and API keys' },\\
      { name: 'Users', description: 'User management' },\\
    ],\\
  },\\
});\\
await app.register(swaggerUi, { routePrefix: '/docs' });" \
          $out/repo/packages/api/src/index.ts

        # 3. Patch Dockerfile.api — use npm install instead of npm ci
        #    (lockfile won't have new swagger deps, npm ci would fail)
        sed -i 's/npm ci /npm install /g' \
          $out/repo/docker/Dockerfile.api
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
