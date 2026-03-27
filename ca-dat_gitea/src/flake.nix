{
  description = "Gitea - Lightweight self-hosted Git service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    giteaConfig = buildJson.gitea;
    mirrors = giteaConfig.mirrors;
    mirrorNames = builtins.attrNames mirrors;

    # GHCR image: wrap public image with OCI label for GHCR
    ghcr = docker.mkGhcrBuild {
      name = "gitea";
      fromImage = "gitea/gitea:latest";
    };

    config = {
      container_name = "gitea";
      image = ghcr.image;
      port_http = buildJson.ports.app;
      port_ssh = buildJson.ssh_port;
      domain = buildJson.domain;
      org = giteaConfig.org;
      mirror_interval = giteaConfig.mirror_interval;
    };

    title = "Gitea - Lightweight self-hosted Git service";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/ca-dat_gitea/src/flake.nix      ║
      # ║ Rebuild: ~/git/cloud/a_solutions/ca-dat_gitea/build.sh ship     ║
      # ╚══════════════════════════════════════════════════════════════════╝
      services:
        gitea:
          image: ${config.image}
          build:
            context: ${ghcr.build.context}
            dockerfile_inline: |
              ${builtins.replaceStrings ["\n"] ["\n        "] ghcr.build.dockerfile_inline}
          container_name: ${config.container_name}
          restart: "no"  # container-init handles startup
          network_mode: host
          env_file:
            - .secrets
          environment:
            GITEA__server__HTTP_PORT: "${toString config.port_http}"
            GITEA__server__SSH_PORT: "${toString config.port_ssh}"
            GITEA__server__DISABLE_SSH: "false"
            GITEA__server__ROOT_URL: "https://${config.domain}"
            GITEA__server__SSH_DOMAIN: "${config.domain}"
            GITEA__mirror__DEFAULT_INTERVAL: "${config.mirror_interval}"
            GITEA__repository__ENABLE_PUSH_CREATE_USER: "true"
            GITEA__repository__ENABLE_PUSH_CREATE_ORG: "true"
          volumes:
            - gitea_data:/data
            - /etc/timezone:/etc/timezone:ro
            - /etc/localtime:/etc/localtime:ro
          healthcheck:
            test: ['CMD', 'curl', '-f', 'http://localhost:${toString config.port_http}/']
            interval: 30s
            timeout: 10s
            retries: 3

      volumes:
        gitea_data:
          driver: local
    '';

    # ── Init script: converge org + mirror repos via Gitea API ─────────
    mkInitScript = pkgs: let
      inherit (pkgs.lib) concatMapStrings;
      mirrorEntries = map (name: {
        inherit name;
        upstream = mirrors.${name}.upstream;
        private = mirrors.${name}.private or false;
      }) mirrorNames;
    in pkgs.writeText "init-mirrors.sh" ''
      #!/usr/bin/env bash
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ AUTO-GENERATED — bootstrap Gitea admin + converge mirror repos  ║
      # ║ Source: build.json .gitea.mirrors + secrets.yaml                ║
      # ║ Run: after container is healthy (container-init calls this)     ║
      # ║ Idempotent: safe to run multiple times                          ║
      # ╚══════════════════════════════════════════════════════════════════╝
      set -uo pipefail
      API="http://localhost:${toString config.port_http}/api/v1"
      CONTAINER="${config.container_name}"

      # ── Step 1: Create admin user (idempotent) ────────────────────
      echo "── Bootstrapping admin user ──"
      docker exec "$CONTAINER" gitea admin user create \
        --username "''${GITEA_ADMIN_USER}" \
        --password "''${GITEA_ADMIN_PASSWORD}" \
        --email "''${GITEA_ADMIN_EMAIL}" \
        --admin \
        --must-change-password=false 2>&1 | grep -v "already exists" || true

      # ── Step 2: Get or create API token ───────────────────────────
      echo "── Obtaining API token ──"
      TOKEN_FILE="/opt/containers/gitea/.gitea-token"
      if [ -f "$TOKEN_FILE" ]; then
        TOKEN=$(cat "$TOKEN_FILE")
      else
        TOKEN=$(curl -sf -X POST "$API/users/''${GITEA_ADMIN_USER}/tokens" \
          -u "''${GITEA_ADMIN_USER}:''${GITEA_ADMIN_PASSWORD}" \
          -H "Content-Type: application/json" \
          -d '{"name":"init-mirrors","scopes":["all"]}' | jq -r '.sha1') || true
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
          echo "$TOKEN" > "$TOKEN_FILE"
          chmod 600 "$TOKEN_FILE"
          echo "  Token created and saved"
        else
          echo "  FAIL: could not create token"
          exit 1
        fi
      fi

      AUTH="-H \"Authorization: token $TOKEN\""
      api() { eval curl -sf "$AUTH" -H "'Content-Type: application/json'" "$@"; }

      # ── Step 3: Ensure org exists ─────────────────────────────────
      echo "── Converging Gitea mirrors ──"
      if ! api "$API/orgs/${config.org}" >/dev/null 2>&1; then
        echo "Creating org: ${config.org}"
        api -X POST "$API/orgs" -d '{"username":"${config.org}","visibility":"public"}' >/dev/null
      fi

      # ── Step 4: Ensure each mirror repo exists ────────────────────
      ${concatMapStrings (m: ''
      if ! api "$API/repos/${config.org}/${m.name}" >/dev/null 2>&1; then
        echo "Creating mirror: ${config.org}/${m.name} ← ${m.upstream}"
        api -X POST "$API/repos/migrate" -d '{
          "clone_addr": "${m.upstream}",
          "repo_name": "${m.name}",
          "repo_owner": "${config.org}",
          "mirror": true,
          "mirror_interval": "${config.mirror_interval}",
          "private": ${if m.private then "true" else "false"},
          "service": "github"
        }' >/dev/null && echo "  OK ${m.name}" || echo "  FAIL ${m.name}"
      else
        echo "EXISTS ${config.org}/${m.name}"
      fi
      '') mirrorEntries}

      echo "── Done ──"
    '';

    # ── Pre-receive hook: block secrets server-side ────────────────────
    mkPreReceiveHook = pkgs: pkgs.writeText "pre-receive" ''
      #!/usr/bin/env bash
      # Server-side secret blocking — NO BYPASS POSSIBLE
      # Deployed to Gitea hooks dir via init script
      while read -r old new ref; do
        [ "$new" = "0000000000000000000000000000000000000000" ] && continue
        FILES=$(git diff --name-only "$old" "$new" 2>/dev/null || git diff-tree --no-commit-id --name-only -r "$new")
        BLOCKED=$(echo "$FILES" | grep -E '\.secrets(\.d/.*)?$|(^|/)\.secrets$|\.secrets/' || true)
        BLOCKED="$BLOCKED"$'\n'$(echo "$FILES" | grep -iE '(id_rsa|id_ed25519|id_ecdsa|\.pem|\.key|\.p12|\.pfx|\.jks|\.keystore)$' | grep -iv '_PUB$' || true)
        BLOCKED="$BLOCKED"$'\n'$(echo "$FILES" | grep -E '(^|/)\.env(\.|$)' | grep -v '\.example' | grep -v '\.template' || true)
        BLOCKED="$BLOCKED"$'\n'$(echo "$FILES" | grep -iE '(\.token|credentials.*\.json|_tokens?\.json|\.asc|\.age|age\.key|keys\.txt|\.tfvars)$' | grep -v '\.example$' | grep -v '\.age\.pub$' || true)
        BLOCKED=$(echo "$BLOCKED" | sort -u | sed '/^$/d')
        if [ -n "$BLOCKED" ]; then
          echo "══════════════════════════════════════════════════" >&2
          echo "REJECTED: secrets detected in push to $ref" >&2
          echo "══════════════════════════════════════════════════" >&2
          echo "$BLOCKED" | while IFS= read -r f; do [ -n "$f" ] && echo "  - $f" >&2; done
          echo "Remove these files and force-push." >&2
          exit 1
        fi
      done
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
      defaultPkg = pkgs.runCommand "gitea-configs" {} ''
        mkdir -p $out/hooks
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkInitScript pkgs} $out/init-mirrors.sh
        cp ${mkPreReceiveHook pkgs} $out/hooks/pre-receive
        chmod +x $out/init-mirrors.sh $out/hooks/pre-receive
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
