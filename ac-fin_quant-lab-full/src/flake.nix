{
  description = "Quant Lab Full - Research + Analytics + ML + Risk + Trading + Postgres";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    config = {
      research_image = "ghcr.io/diegonmarcos/quant-full-research:latest";
      analytics_image = "ghcr.io/diegonmarcos/quant-full-analytics:latest";
      ml_image = "ghcr.io/diegonmarcos/quant-full-ml:latest";
      risk_image = "ghcr.io/diegonmarcos/quant-full-risk:latest";
      engine_image = "ghcr.io/diegonmarcos/quant-full-engine:latest";
      db_image = "ghcr.io/diegonmarcos/quant-full-db:latest";
      jupyter_port = ports.valueOf "research";
      dash_port = 8050;
      engine_port = 5000;
      db_port = ports.valueOf "db";
    };

    title = "Quant Lab Full - Research + Analytics + ML + Risk + Trading + Postgres";
    docker = import ../../_shared/docker.nix;

    ghcr-quant-research = docker.mkGhcrBuild {
      name = "quant-full-research";
      fromImage = config.research_image;
    };

    ghcr-quant-analytics = docker.mkGhcrBuild {
      name = "quant-full-analytics";
      fromImage = config.analytics_image;
    };

    ghcr-quant-ml = docker.mkGhcrBuild {
      name = "quant-full-ml";
      fromImage = config.ml_image;
    };

    ghcr-quant-risk = docker.mkGhcrBuild {
      name = "quant-full-risk";
      fromImage = config.risk_image;
    };

    ghcr-quant-engine = docker.mkGhcrBuild {
      name = "quant-full-engine";
      fromImage = config.engine_image;
    };

    ghcr-quant-db = docker.mkGhcrBuild {
      name = "quant-full-db";
      fromImage = config.db_image;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ac-fin_quant-lab-full/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/ac-fin_quant-lab-full/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        research:
          image: ${ghcr-quant-research.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.research_image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: quant_full_research
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - ./notebooks:/home/jovyan/work
            - shared_data:/home/jovyan/data
          environment:
            JUPYTER_ENABLE_LAB: "yes"
          command: >
            sh -c "pip install openbb polars plotly &&
                   start-notebook.sh --NotebookApp.token=''' --ServerApp.port=${toString config.jupyter_port}"
          healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost:${toString config.jupyter_port}/api || exit 1"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 60s

        analytics:
          image: ${ghcr-quant-analytics.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.analytics_image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: quant_full_analytics
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - ./scripts:/app
            - shared_data:/data
          working_dir: /app
          command: >
            sh -c "pip install polars numpy scipy pandas matplotlib seaborn plotly dash &&
                   tail -f /dev/null"

        ml_brain:
          image: ${ghcr-quant-ml.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.ml_image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: quant_full_ml
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - ./models:/workspace/models
            - shared_data:/data
          working_dir: /workspace
          # Uncomment for GPU support:
          # deploy:
          #   resources:
          #     reservations:
          #       devices:
          #         - driver: nvidia
          #           count: 1
          #           capabilities: [gpu]
          command: >
            sh -c "pip install torch scikit-learn lightgbm pycaret xgboost &&
                   tail -f /dev/null"

        risk_manager:
          image: ${ghcr-quant-risk.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.risk_image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: quant_full_risk
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - ./risk_reports:/reports
            - shared_data:/data
          working_dir: /reports
          command: >
            sh -c "pip install riskfolio-lib quantstats cvxpy &&
                   tail -f /dev/null"

        execution_engine:
          image: ${ghcr-quant-engine.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.engine_image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: quant_full_engine
          restart: "no"  # container-init handles startup
          network_mode: host
          volumes:
            - ./strategies:/app/strategies
            - shared_data:/data
          working_dir: /app
          command: >
            sh -c "pip install nautilus_trader ib_insync &&
                   tail -f /dev/null"

        database:
          image: ${ghcr-quant-db.image}
          build:
            context: .
            dockerfile_inline: |
              FROM ${config.db_image}
              LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
          container_name: quant_full_db
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            POSTGRES_USER: ''${POSTGRES_USER}
            POSTGRES_PASSWORD: ''${POSTGRES_PASSWORD}
            POSTGRES_DB: ''${POSTGRES_DB}
            PGPORT: "${toString config.db_port}"
          volumes:
            - pg_data:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ''${POSTGRES_USER} -d ''${POSTGRES_DB}"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s

      volumes:
        pg_data:
          name: quant_full_pg_data
        shared_data:
          name: quant_full_shared_data

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
      defaultPkg = pkgs.runCommand "quant-lab-full-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
