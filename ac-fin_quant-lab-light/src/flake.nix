{
  description = "Quant Lab Light - Jupyter + NautilusTrader + Postgres";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      research_image = "quay.io/jupyter/scipy-notebook:latest";
      engine_image = "python:3.12-slim";
      db_image = "postgres:16-alpine";
      jupyter_port = 8889;
      engine_port = 5001;
      db_port = 5434;
    };

    title = "Quant Lab Light - Jupyter + NautilusTrader + Postgres";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        research:
          image: ${config.research_image}
          container_name: quant_light_research
          restart: unless-stopped
          ports:
            - "${toString config.jupyter_port}:8888"
          volumes:
            - ./notebooks:/home/jovyan/work
            - ./data:/home/jovyan/data
          environment:
            JUPYTER_ENABLE_LAB: "yes"
            GRANT_SUDO: "yes"
          command: >
            sh -c "pip install polars openbb quantstats riskfolio-lib plotly &&
                   start-notebook.sh --NotebookApp.token='''"
          networks:
            - quant_network
          healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost:8888/api || exit 1"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 60s

        engine:
          image: ${config.engine_image}
          container_name: quant_light_engine
          restart: unless-stopped
          ports:
            - "${toString config.engine_port}:5000"
          volumes:
            - ./strategies:/app/strategies
            - ./data:/app/data
          working_dir: /app
          depends_on:
            - research
          command: >
            sh -c "pip install nautilus_trader ib_insync &&
                   tail -f /dev/null"
          networks:
            - quant_network

        db:
          image: ${config.db_image}
          container_name: quant_light_db
          restart: unless-stopped
          ports:
            - "${toString config.db_port}:5432"
          env_file:
            - .secrets
          environment:
            POSTGRES_USER: ''${POSTGRES_USER}
            POSTGRES_PASSWORD: ''${POSTGRES_PASSWORD}
            POSTGRES_DB: ''${POSTGRES_DB}
          volumes:
            - postgres_data:/var/lib/postgresql/data
          networks:
            - quant_network
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ''${POSTGRES_USER} -d ''${POSTGRES_DB}"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s

      volumes:
        postgres_data:
          name: quant_light_postgres_data

      networks:
        quant_network:
          name: quant_light_network
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
      defaultPkg = pkgs.runCommand "quant-lab-light-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
