{
  description = "Dagu - Lightweight DAG-based workflow scheduler";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "dagu";
      image = "ghcr.io/dagu-org/dagu:1.30.3";
      port = 8070;
    };

    title = "Dagu - Lightweight DAG-based workflow scheduler";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        dagu:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          entrypoint: []
          command: ["dagu", "start-all"]
          ports:
            - "10.0.0.3:${toString config.port}:8080"
          environment:
            - DAGU_HOST=0.0.0.0
            - DAGU_PORT=8080
            - DAGU_DAGS_DIR=/var/lib/dagu/dags
            - DAGU_BASE_CONFIG=/var/lib/dagu/base.yaml
            - DAGU_AUTH_MODE=basic
            - DAGU_AUTH_BASIC_USERNAME=''${DAGU_USERNAME}
            - DAGU_AUTH_BASIC_PASSWORD=''${DAGU_PASSWORD}
            - DAGU_TZ=Europe/Berlin
            - BEARER_TOKEN=''${BEARER_TOKEN}
          volumes:
            - dagu-data:/var/lib/dagu
            - ./dags:/var/lib/dagu/dags:ro
            - ./base.yaml:/var/lib/dagu/base.yaml:ro
          mem_limit: 64m
          networks:
            - default
            - mailu_default

      volumes:
        dagu-data:
          driver: local

      networks:
        mailu_default:
          external: true
    '';

    # ── Base config: SMTP + default notifications ────────────────────────
    mkBaseConfig = pkgs: pkgs.writeText "base.yaml" ''
      smtp:
        host: mailu-smtp-1
        port: "25"
        username: ""
        password: ""

      mailOn:
        failure: true
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

    # ── DAG workflows ────────────────────────────────────────────────────
    mkDags = pkgs: {

      healthcheck = pkgs.writeText "healthcheck.yaml" ''
        schedule: "*/5 * * * *"

        env:
          - NTFY_URL: https://rss.diegonmarcos.com
          - BEARER_TOKEN: ''${BEARER_TOKEN}

        mailOn:
          failure: true
          success: false

        steps:
          - name: check-hub
            command: bash -c "echo QUIT | /usr/bin/timeout 3 bash -c 'cat > /dev/tcp/10.0.0.1/22'"
            retryPolicy:
              limit: 1
              intervalSec: 5
          - name: check-mail
            command: bash -c "echo QUIT | /usr/bin/timeout 3 bash -c 'cat > /dev/tcp/10.0.0.3/25'"
          - name: check-analytics
            command: bash -c "echo QUIT | /usr/bin/timeout 3 bash -c 'cat > /dev/tcp/10.0.0.4/22'"

        handlerOn:
          failure:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"infra","title":"Mesh Health FAILED","message":"One or more always-on peers unreachable","priority":5,"tags":["rotating_light"]}
            command: POST ''${NTFY_URL}

          success:
            type: http
            config:
              headers:
                Content-Type: application/json
                Authorization: "Bearer ''${BEARER_TOKEN}"
              body: |
                {"topic":"infra","title":"Mesh Health OK","message":"All always-on peers reachable","priority":2,"tags":["white_check_mark"]}
            command: POST ''${NTFY_URL}
      '';
    };

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
      dags = mkDags pkgs;
    in let
      defaultPkg = pkgs.runCommand "dagu-configs" {} ''
        mkdir -p $out/dags
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkBaseConfig pkgs} $out/base.yaml
        cp ${dags.healthcheck} $out/dags/healthcheck.yaml
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
