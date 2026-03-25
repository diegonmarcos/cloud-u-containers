{
  description = "Dagu - Lightweight DAG-based workflow scheduler";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      container_name = "dagu";
      image = "ghcr.io/dagu-org/dagu:1.30.3";
      port = buildJson.ports.app;
      domain = buildJson.domain;
    };

    title = "Dagu - Lightweight DAG-based workflow scheduler";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/bc-obs_dagu/src/flake.nix       ║
      # ║ Rebuild: ~/git/cloud/a_solutions/bc-obs_dagu/build.sh ship      ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        dagu:
          build:
            context: .
            dockerfile: Dockerfile
          image: dagu-ssh:local
          container_name: ${config.container_name}
          entrypoint: ["dagu", "start-all"]
          restart: unless-stopped
          network_mode: host
          environment:
            - DAGU_HOST=0.0.0.0
            - DAGU_PORT=${toString config.port}
            - DAGU_DAGS_DIR=/var/lib/dagu/dags
            - DAGU_BASE_CONFIG=/var/lib/dagu/base.yaml
            - DAGU_AUTH_MODE=basic
            - DAGU_AUTH_BASIC_USERNAME=''${DAGU_USERNAME}
            - DAGU_AUTH_BASIC_PASSWORD=''${DAGU_PASSWORD}
            - DAGU_TZ=Europe/Berlin
            - DAGU_UI_NAVBAR_COLOR=#1a1a2e
            - DAGU_UI_LOGO_TITLE=C3 Workflows
            - AUTHELIA_OIDC_CLIENT_ID=dagu-cc
            - AUTHELIA_OIDC_CLIENT_SECRET=''${AUTHELIA_OIDC_DAGU_SECRET}
            - AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token
          env_file:
            - .secrets
          volumes:
            - ./data:/var/lib/dagu/data
            - ./dags:/var/lib/dagu/dags
            - ./base.yaml:/var/lib/dagu/base.yaml:ro
            - ./fetch-token.sh:/var/lib/dagu/fetch-token.sh:ro
            - /opt/ssh-keys/dagu:/root/.ssh:ro
          mem_limit: 256m

    '';

    # ── Base config: SMTP + default notifications ────────────────────────
    mkBaseConfig = pkgs: pkgs.writeText "base.yaml" ''
      shell: /bin/bash

      smtp:
        host: mailu.app
        port: "25"
        username: ""
        password: ""

      mailOn:
        failure: false
        success: false

      errorMail:
        from: no-reply@diegonmarcos.com
        to:
          - me@diegonmarcos.com
        prefix: "[Dagu FAIL]"
        attachLogs: true

      infoMail:
        from: no-reply@diegonmarcos.com
        to:
          - me@diegonmarcos.com
        prefix: "[Dagu OK]"
    '';

    # ── OIDC token fetch entrypoint ───────────────────────────────────────
    mkFetchToken = pkgs: pkgs.writeText "fetch-token.sh" ''
      #!/bin/sh

      # Fetch OIDC token via client_credentials grant, export as AUTHELIA_BEARER_TOKEN
      # so all existing DAG workflows keep working without changes.
      # Starts dagu regardless — token failure is non-fatal (DAGs using bearer will fail individually).
      echo "[fetch-token] Requesting OIDC token from $AUTHELIA_TOKEN_URL ..."
      RESPONSE=$(curl -s --max-time 10 -X POST "$AUTHELIA_TOKEN_URL" \
        -u "$AUTHELIA_OIDC_CLIENT_ID:$AUTHELIA_OIDC_CLIENT_SECRET" \
        -d "grant_type=client_credentials&scope=authelia.bearer.authz" 2>&1) || true

      TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      if [ -n "$TOKEN" ]; then
        export AUTHELIA_BEARER_TOKEN="$TOKEN"
        echo "[fetch-token] Token acquired (''${#TOKEN} chars)"
      else
        echo "[fetch-token] WARNING: Failed to get OIDC token — dagu will start without bearer auth"
        echo "[fetch-token] Response: $RESPONSE"
      fi

      exec dagu start-all
    '';

    # ── SSH shorthand used across all workflows ──────────────────────────
    sshCmd = "ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR";
    # VM list derived from monitoring-targets.json at runtime (fallback to hardcoded)
    monTargets = "/var/lib/dagu/data/cloud-data/cloud-data-monitoring-targets.json";
    vmListCmd = ''
      if [ -f "${monTargets}" ]; then
        jq -r '.vms[] | "\(.ip):\(.name):\(.user)"' "${monTargets}" | tr '\n' ' '
      else
        echo "10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu"
      fi
    '';

    # ── DAG workflows ────────────────────────────────────────────────────
    # DAGs live in src/dags/*.yaml (file-based, not inline Nix).
    # The flake copies them to dist/dags/ via: cp -r ${./dags}/. $out/dags/
    # This keeps DAGs portable — same files work in Dagu, CLI, or any runner.
    # Old inline mkDags (1730 lines) removed — see git history.


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
      defaultPkg = pkgs.runCommand "dagu-configs" {} ''
        mkdir -p $out/dags
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkBaseConfig pkgs} $out/base.yaml
        cp ${mkFetchToken pkgs} $out/fetch-token.sh
        chmod +x $out/fetch-token.sh
        cp ${./Dockerfile} $out/Dockerfile
        cp -r ${./dags}/. $out/dags/
        chmod +x $out/dags/report_daily.sh 2>/dev/null || true
        chmod +x $out/dags/gha/*.sh 2>/dev/null || true
        # Prevent Dagu from overwriting our DAGs with example files on first start
        touch $out/dags/.examples-created
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
