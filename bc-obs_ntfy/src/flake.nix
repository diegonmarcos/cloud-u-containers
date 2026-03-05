{
  description = "ntfy Push Notifications + syslog-bridge + github-rss";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "rss.diegonmarcos.com";
      container_name = "ntfy";
      image = "binwiederhier/ntfy";
      port = 8090;
    };

    title = "ntfy Push Notifications + syslog-bridge + github-rss";

    mkServerConfig = pkgs: pkgs.writeText "server.yml" ''
      # ntfy server configuration
      base-url: https://${config.domain}

      # Cache and retention
      cache-file: /var/cache/ntfy/cache.db
      cache-duration: 720h
      attachment-cache-dir: /var/cache/ntfy/attachments

      # Limits
      visitor-request-limit-burst: 60
      visitor-request-limit-replenish: 10s
      visitor-message-daily-limit: 0

      # Auth — admin API access (Caddy injects credentials, anonymous r/w preserved)
      auth-file: /var/cache/ntfy/auth.db
      auth-default-access: read-write

      # Web interface
      enable-login: true
      enable-signup: false
      enable-reservations: false

      # Behind reverse proxy (Authelia handles auth)
      behind-proxy: true
    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ntfy - Push Notification Server
      # Deployed on: gcp-E2-f_0 (35.226.147.64)
      # Domain: ${config.domain}

      services:
        ntfy:
          image: ${config.image}
          container_name: ${config.container_name}
          entrypoint:
            - /bin/sh
            - -c
            - |
              NTFY_PASSWORD="$$NTFY_ADMIN_PASSWORD" ntfy user add --role=admin admin 2>/dev/null || true
              NTFY_PASSWORD="$$NTFY_ADMIN_PASSWORD" ntfy user change-pass admin 2>/dev/null || true
              NTFY_PASSWORD="$$NTFY_USER_PASSWORD" ntfy user add diego 2>/dev/null || true
              NTFY_PASSWORD="$$NTFY_USER_PASSWORD" ntfy user change-pass diego 2>/dev/null || true
              exec ntfy serve
          env_file:
            - .secrets
          environment:
            - TZ=Europe/Paris
          volumes:
            - ./cache:/var/cache/ntfy
            - ./etc:/etc/ntfy
          ports:
            - '10.0.0.1:${toString config.port}:80'
          restart: unless-stopped
          dns:
            - 8.8.8.8
            - 1.1.1.1
          networks:
            - npm_default

        syslog-bridge:
          image: python:3.11-slim
          container_name: syslog-bridge
          command: python -u /app/syslog-to-ntfy.py
          volumes:
            - ./syslog-to-ntfy.py:/app/syslog-to-ntfy.py:ro
            - ./cache:/var/cache/ntfy
            - syslog-central-logs:/var/log:ro
          environment:
            - TZ=Europe/Paris
            - PYTHONUNBUFFERED=1
          depends_on:
            - ntfy
          restart: unless-stopped
          dns:
            - 8.8.8.8
          networks:
            - npm_default

        github-rss:
          image: python:3.11-slim
          container_name: github-rss
          command: python -u /app/github-rss-to-ntfy.py
          volumes:
            - ./github-rss-to-ntfy.py:/app/github-rss-to-ntfy.py:ro
            - ./cache:/var/cache/ntfy
          environment:
            - TZ=Europe/Paris
            - PYTHONUNBUFFERED=1
          depends_on:
            - ntfy
          restart: unless-stopped
          dns:
            - 8.8.8.8
            - 1.1.1.1
          networks:
            - npm_default

      volumes:
        syslog-central-logs:
          external: true

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
      defaultPkg = pkgs.runCommand "ntfy-configs" {} ''
        mkdir -p $out/etc
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkServerConfig pkgs} $out/etc/server.yml
        cp ${./syslog-to-ntfy.py} $out/syslog-to-ntfy.py
        cp ${./github-rss-to-ntfy.py} $out/github-rss-to-ntfy.py
        cp ${./topic-scanner.py} $out/topic-scanner.py
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
