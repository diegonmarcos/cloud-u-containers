{
  description = "Umami Analytics - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "analytics.diegonmarcos.com/umami";
      container_name = "umami";
      port = 3000;
      db_container = "umami-db";
    };

    title = "Umami Analytics";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_umami/src/flake.nix     ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_umami/build.sh ship    ║
      # ╚══════════════════════════════════════════════════════════════════╝
      # Umami Analytics (lightweight, always-on)
      # VM: oci-E2-f_1 (129.151.228.66)
      # URL: https://${config.domain}

      services:
        umami:
          image: ghcr.io/umami-software/umami:latest
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "10.0.0.4:${toString config.port}:3000"
          env_file:
            - .secrets
          environment:
            DATABASE_URL: postgresql://umami:''${DB_PASSWORD}@umami-db:5432/umami
            DATABASE_TYPE: postgresql
            APP_SECRET: ''${APP_SECRET}
            BASE_PATH: /umami
            DISABLE_TELEMETRY: "1"
          depends_on:
            umami-db:
              condition: service_healthy
          healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost:3000/umami/api/heartbeat || exit 1"]
            interval: 15s
            timeout: 5s
            retries: 5
            start_period: 30s
          deploy:
            resources:
              limits:
                memory: 128M
              reservations:
                memory: 32M

        umami-db:
          image: postgres:16-alpine
          container_name: ${config.db_container}
          restart: unless-stopped
          environment:
            POSTGRES_DB: umami
            POSTGRES_USER: umami
            POSTGRES_PASSWORD: ''${DB_PASSWORD}
          volumes:
            - umami_db_data:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U umami"]
            interval: 10s
            timeout: 5s
            retries: 5
          deploy:
            resources:
              limits:
                memory: 128M
              reservations:
                memory: 32M

        umami-setup:
          image: curlimages/curl:latest
          container_name: umami-setup
          restart: "no"
          env_file:
            - .secrets
          depends_on:
            umami:
              condition: service_healthy
          entrypoint: ["/bin/sh", "/setup/setup.sh"]
          volumes:
            - ./setup.sh:/setup/setup.sh:ro
            - umami_config:/output

      volumes:
        umami_db_data:
          name: umami_db_data
        umami_config:
          name: umami_config
    '';

    mkSetupScript = pkgs: pkgs.writeText "setup.sh" ''
      #!/bin/sh
      # Umami declarative setup — runs once after first deploy
      # Configures admin credentials + creates website
      set -e

      UMAMI_URL="http://umami:3000/umami"
      echo "[umami-setup] Starting..."

      # Login with default credentials (admin/umami)
      echo "[umami-setup] Attempting default login..."
      RESP=$(curl -sf "$UMAMI_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"umami"}' 2>/dev/null || echo "")
      TOKEN=$(echo "$RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

      if [ -z "$TOKEN" ]; then
        # Default login failed — try configured credentials
        echo "[umami-setup] Default login failed, trying configured credentials..."
        RESP=$(curl -sf "$UMAMI_URL/api/auth/login" \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "")
        TOKEN=$(echo "$RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

        if [ -z "$TOKEN" ]; then
          echo "[umami-setup] ERROR: Cannot authenticate"
          exit 1
        fi
        echo "[umami-setup] Already configured, verifying website..."
      else
        # Change admin password
        echo "[umami-setup] Changing admin password..."
        curl -sf "$UMAMI_URL/api/me/password" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -d "{\"currentPassword\":\"umami\",\"newPassword\":\"$ADMIN_PASSWORD\"}" >/dev/null

        # Change admin username
        echo "[umami-setup] Setting admin username to $ADMIN_USERNAME..."
        curl -sf "$UMAMI_URL/api/me" \
          -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -d "{\"username\":\"$ADMIN_USERNAME\"}" >/dev/null

        # Re-login with new credentials
        RESP=$(curl -sf "$UMAMI_URL/api/auth/login" \
          -H "Content-Type: application/json" \
          -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "")
        TOKEN=$(echo "$RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
        echo "[umami-setup] Admin credentials updated"
      fi

      # Check if website exists
      SITES=$(curl -sf "$UMAMI_URL/api/websites" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "")

      if echo "$SITES" | grep -q "diegonmarcos.com"; then
        echo "[umami-setup] Website diegonmarcos.com already exists"
        SITE_ID=$(echo "$SITES" | sed -n 's/.*"websiteId":"\([^"]*\)".*"domain":"diegonmarcos.com".*/\1/p')
        # Try alternative field order
        [ -z "$SITE_ID" ] && SITE_ID=$(echo "$SITES" | sed -n 's/.*"domain":"diegonmarcos.com".*"websiteId":"\([^"]*\)".*/\1/p')
      else
        echo "[umami-setup] Creating website diegonmarcos.com..."
        RESP=$(curl -sf "$UMAMI_URL/api/websites" \
          -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -d '{"name":"Diego Portfolio","domain":"diegonmarcos.com"}' 2>/dev/null || echo "")
        SITE_ID=$(echo "$RESP" | sed -n 's/.*"websiteId":"\([^"]*\)".*/\1/p')
      fi

      # Write SITE_ID to persistent volume for declarative retrieval
      echo "$SITE_ID" > /output/site_id
      echo "{\"umami_site_id\":\"$SITE_ID\",\"umami_url\":\"https://analytics.diegonmarcos.com/umami\"}" > /output/analytics.json

      echo ""
      echo "========================================="
      echo "  Umami Setup Complete"
      echo "  Login:      https://analytics.diegonmarcos.com/umami"
      echo "  User:       $ADMIN_USERNAME"
      echo "  Website ID: $SITE_ID"
      echo "  Config:     /output/analytics.json"
      echo "========================================="
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
      defaultPkg = pkgs.runCommand "umami-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkSetupScript pkgs} $out/setup.sh
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
