{
  description = "Cloud API (Flask) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "api.diegonmarcos.com";
      container_name = "flask-api";
      port = 5000;
    };

    title = "Cloud API (Flask)";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        flask-api:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:5000"
          volumes:
            - c3-data:/app/c3-data:ro
            - /home/diego/cloud/architecture.json:/app/config/architecture.json:ro
            - ~/.ssh:/home/appuser/.ssh:ro
            - /home/diego/cloud/oci_config:/app/config/oci_config:ro
            - /home/diego/cloud/oci_api_key.pem:/app/config/oci_api_key.pem:ro
            - /home/diego/cloud/gcp_key.json:/app/config/gcp_key.json:ro
          environment:
            - FLASK_DEBUG=false
            - CLOUD_CONFIG_PATH=/app/config/architecture.json
            - OCI_CONFIG_FILE=/app/config/oci_config
            - OCI_KEY_FILE=/app/config/oci_api_key.pem
            - OCI_WAKE_INSTANCE_ID=''${OCI_WAKE_INSTANCE_ID}
            - OCI_FLEX1_INSTANCE_ID=''${OCI_FLEX1_INSTANCE_ID}
            - OCI_MICRO1_INSTANCE_ID=''${OCI_MICRO1_INSTANCE_ID}
            - OCI_MICRO2_INSTANCE_ID=''${OCI_MICRO2_INSTANCE_ID}
            - GCP_SERVICE_ACCOUNT_FILE=/app/config/gcp_key.json
            - GCP_PROJECT_ID=''${GCP_PROJECT_ID}
            - SSH_KEY_PATH=/home/appuser/.ssh/id_rsa
            - GCP_SSH_KEY_PATH=/home/appuser/.ssh/google_compute_engine
            - AUTHELIA_BEARER_TOKEN=''${AUTHELIA_BEARER_TOKEN:-}
            - CORS_ORIGINS=https://api.diegonmarcos.com,https://diegonmarcos.github.io,http://localhost:*,http://127.0.0.1:*
            - CF_API_TOKEN=''${CF_API_TOKEN}
            - CF_ZONE_ID=''${CF_ZONE_ID}
            - NTFY_URL=http://ntfy:80
            - NTFY_TOKEN=''${NTFY_TOKEN}
          networks:
            - npm_default
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:5000/api/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s

      volumes:
        c3-data:
          name: c3-data

      networks:
        npm_default:
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
      defaultPkg = pkgs.runCommand "flask-api-configs" {} ''
        mkdir -p $out/app/api $out/app/data $out/app/models $out/app/utils
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./requirements.txt} $out/requirements.txt
        cp ${./run.py} $out/run.py
        # Flask app
        cp ${./app/__init__.py} $out/app/__init__.py
        cp ${./app/config.py} $out/app/config.py
        cp ${./app/api/__init__.py} $out/app/api/__init__.py
        cp ${./app/api/admin.py} $out/app/api/admin.py
        cp ${./app/api/alerts.py} $out/app/api/alerts.py
        cp ${./app/api/auth.py} $out/app/api/auth.py
        cp ${./app/api/c3.py} $out/app/api/c3.py
        cp ${./app/api/routes.py} $out/app/api/routes.py
        cp ${./app/api/cloudflare.py} $out/app/api/cloudflare.py
        cp ${./app/api/web.py} $out/app/api/web.py
        cp ${./app/data/cloud_architecture.json} $out/app/data/cloud_architecture.json
        cp ${./app/data/cloud_control.json} $out/app/data/cloud_control.json
        cp ${./app/models/__init__.py} $out/app/models/__init__.py
        cp ${./app/utils/__init__.py} $out/app/utils/__init__.py
        cp ${./app/utils/health.py} $out/app/utils/health.py
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
