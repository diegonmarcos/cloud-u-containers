{
  description = "Rig Agentic AI - Infrastructure agent with DeepSeek + tool calling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-rig-agentic-sonn-14bq8.json (symlink →
    # I_cloud-data/build-rig-agentic-sonn-14bq8.json). Engine resolves
    # symlink before nix build.
    buildRig = builtins.fromJSON (builtins.readFile ./build-rig-agentic-sonn-14bq8.json);
    svc = buildRig.services;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    # Upstream service lookups from cloud-data
    ollamaSvc = svc.${buildJson.rig.ollama_service};
    mattermostSvc = svc.${buildJson.rig.mattermost_service};
    selfSvc = svc.${buildJson.name};

    config = {
      container_name = buildRig.container.container_name;
      image = "${buildJson.docker.registry}/${buildJson.docker.image}:latest";
      port = ports.valueOf "app";
      rig_host = selfSvc.ip;
      ollama_url = "http://${ollamaSvc.ip}:${toString ollamaSvc.ports.app}";
      ollama_model = buildJson.rig.ollama_model;
      c3_api_url = buildJson.rig.c3_api_url;
      c3_mcp_url = buildJson.rig.c3_mcp_url;
      mattermost_url = "http://${mattermostSvc.ip}:${toString mattermostSvc.ports.app}";
      mm_bot_mention = buildJson.rig.mm_bot_mention;
      guardrail_max_turns = toString buildJson.rig.guardrail_max_turns;
      self_healing_enabled = if buildJson.rig.self_healing_enabled then "true" else "false";
      rust_log = buildJson.rig.rust_log;
    };

    title = "Rig Agentic AI";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ad-agi_rig-agentic-sonn-14bq8/     ║
      # ║ Rebuild: build.sh ship                                              ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        rig-agentic-sonn-14bq8:
          build:
            context: .
            dockerfile: Dockerfile
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            - RIG_HOST=${config.rig_host}
            - RIG_PORT=${toString config.port}
            - OLLAMA_URL=${config.ollama_url}
            - OLLAMA_API_BASE_URL=${config.ollama_url}
            - OLLAMA_MODEL=${config.ollama_model}
            - C3_API_URL=${config.c3_api_url}
            - C3_MCP_URL=${config.c3_mcp_url}
            - MATTERMOST_URL=${config.mattermost_url}
            - GUARDRAIL_MAX_TURNS=${config.guardrail_max_turns}
            - GUARDRAIL_DENIED_TOOLS=
            - GUARDRAIL_ALLOWED_TOOLS=
            - SELF_HEALING_ENABLED=${config.self_healing_enabled}
            - MM_BOT_MENTION=${config.mm_bot_mention}
            - RUST_LOG=${config.rust_log}
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
          healthcheck:
            test: ["CMD", "curl", "-sf", "http://${config.rig_host}:${toString config.port}/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 15s

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
      defaultPkg = pkgs.runCommand "rig-agentic-sonn-14bq8-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
