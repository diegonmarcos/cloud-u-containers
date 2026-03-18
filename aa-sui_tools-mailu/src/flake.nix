{
  description = "Mailu Mail Server - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # Non-secret configuration (secrets come from .secrets via envsubst)
    config = {
      domain = "diegonmarcos.com";
      mail_domain = "mail.diegonmarcos.com";
      hostname = "mail";
      timezone = "Europe/Madrid";

      # Subnet for Mailu internal network
      subnet = "172.16.203.0/24";

      # Message size limit (50MB)
      message_size_limit = "50000000";

      # Public IP (OCI micro)
      public_ip = "130.110.251.193";

      # OCI Email Delivery relay (primary while AWS SES is in sandbox)
      oci_relay_host = "smtp.email.eu-marseille-1.oci.oraclecloud.com";
      oci_relay_port = "587";

      # AWS SES relay (fallback, swap to primary once production access granted)
      aws_relay_host = "email-smtp.us-east-1.amazonaws.com";
      aws_relay_port = "587";
    };

    title = "Mailu Mail Server";

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ DO NOT EDIT — DECLARATIVE ENVIRONMENT — NIX FLAKES WAY         ║
      # ║ AUTO-GENERATED — DONT USE IMPERATIVE SOLUTIONS!!!              ║
      # ╠══════════════════════════════════════════════════════════════════╣
      # ║ Source: ~/git/cloud/a_solutions/aa-sui_tools-mailu/src/flake.nix ║
      # ║ Rebuild: ~/git/cloud/a_solutions/aa-sui_tools-mailu/build.sh ship ║
      # ╚══════════════════════════════════════════════════════════════════╝
      version: "3.8"

      services:
        resolver:
          image: ghcr.io/mailu/unbound:2024.06.48
          env_file: mailu.env
          restart: always
          healthcheck:
            test: ["CMD", "dig", "+short", "@127.0.0.1", "google.com"]
            interval: 30s
            timeout: 5s
            retries: 3
            start_period: 10s
          networks:
            default:
              ipv4_address: 172.16.203.254

        front:
          image: ghcr.io/mailu/nginx:2024.06.48
          env_file: mailu.env
          restart: always
          ports:
            - "10.0.0.3:8444:443"
            - "0.0.0.0:25:25"
            - "0.0.0.0:465:465"
            - "0.0.0.0:587:587"
            - "0.0.0.0:993:993"
          volumes:
            - "./certs:/certs"
            - "./overrides/nginx:/overrides:ro"
          depends_on:
            resolver:
              condition: service_healthy
          dns:
            - 172.16.203.254

        admin:
          image: ghcr.io/mailu/admin:2024.06.48
          env_file: mailu.env
          restart: always
          volumes:
            - "./data:/data"
            - "./dkim:/dkim"
          depends_on:
            resolver:
              condition: service_healthy
            redis:
              condition: service_started
          dns:
            - 172.16.203.254

        imap:
          image: ghcr.io/mailu/dovecot:2024.06.48
          env_file: mailu.env
          restart: always
          volumes:
            - "./mail:/mail"
            - "./overrides/dovecot:/overrides:ro"
          depends_on:
            resolver:
              condition: service_healthy
            front:
              condition: service_started
          dns:
            - 172.16.203.254

        smtp:
          image: ghcr.io/mailu/postfix:2024.06.48
          env_file: mailu.env
          restart: always
          volumes:
            - "./mailqueue:/queue"
            - "./overrides/postfix:/overrides:ro"
          depends_on:
            resolver:
              condition: service_healthy
            front:
              condition: service_started
          dns:
            - 172.16.203.254

        antispam:
          image: ghcr.io/mailu/rspamd:2024.06.48
          env_file: mailu.env
          restart: always
          volumes:
            - "./filter:/var/lib/rspamd"
            - "./overrides/rspamd:/overrides:ro"
          depends_on:
            resolver:
              condition: service_healthy
            front:
              condition: service_started
          dns:
            - 172.16.203.254

        redis:
          image: redis:7-bookworm
          restart: always
          volumes:
            - "./redis:/data"

        webmail:
          image: ghcr.io/mailu/webmail:2024.06.48
          env_file: mailu.env
          restart: always
          volumes:
            - "./webmail:/data"
            - "./overrides/roundcube:/overrides:ro"
          depends_on:
            resolver:
              condition: service_healthy
            front:
              condition: service_started
            imap:
              condition: service_started
          dns:
            - 172.16.203.254

      networks:
        default:
          driver: bridge
          ipam:
            driver: default
            config:
              - subnet: ${config.subnet}
    '';

    # Mailu env template — secrets use ''${VAR} placeholders, substituted by init.sh
    mkMailuEnvTpl = pkgs: pkgs.writeText "mailu.env.tpl" ''
      # Mailu main configuration file
      DOMAIN=${config.domain}
      HOSTNAMES=${config.mail_domain},imap.${config.domain},smtp.${config.domain}
      POSTMASTER=me

      SECRET_KEY=''\${SECRET_KEY}
      SUBNET=${config.subnet}

      WEBMAIL=roundcube
      WEB_ADMIN=/admin
      WEB_WEBMAIL=/webmail

      BIND_ADDRESS4=0.0.0.0
      HTTP_PORT=80
      HTTPS_PORT=443
      SMTP_PORT=25
      IMAP_PORT=993
      SUBMISSION_PORT=587

      TLS_FLAVOR=cert

      AUTH_RATELIMIT_IP=60/hour
      AUTH_RATELIMIT_USER=100/day

      ANTIVIRUS=none
      ANTISPAM=rspamd
      ADMIN=true
      WEBDAV=none
      FETCHMAIL=false

      RELAYHOST=[${config.oci_relay_host}]:${config.oci_relay_port}
      OCI_RELAYUSER=''\${OCI_RELAYUSER}
      OCI_RELAYPASSWORD=''\${OCI_RELAYPASSWORD}
      AWS_RELAYUSER=''\${AWS_RELAYUSER}
      AWS_RELAYPASSWORD=''\${AWS_RELAYPASSWORD}

      MESSAGE_SIZE_LIMIT=${config.message_size_limit}

      INITIAL_ADMIN_ACCOUNT=me
      INITIAL_ADMIN_DOMAIN=${config.domain}
      INITIAL_ADMIN_PW=''\${INITIAL_ADMIN_PW}

      SITENAME=Diego Mail
      WEBSITE=https://${config.mail_domain}

      DB_FLAVOR=sqlite
      LOG_LEVEL=INFO
      CREDENTIAL_ROUNDS=12

      PUBLICIP=${config.public_ip}

      REJECT_UNLISTED_RECIPIENT=yes
      REAL_IP_HEADER=X-Forwarded-For

      PROXY_AUTH_WHITELIST=35.226.147.64
      PROXY_AUTH_HEADER=X-Forwarded-User
      PROXY_AUTH_CREATE=False
    '';

    # Init script: sources .secrets, runs envsubst on template, decodes DKIM key
    mkInitSh = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e
      cd "$(dirname "$0")"

      ENV_VARS='$SECRET_KEY $INITIAL_ADMIN_PW $OCI_RELAYUSER $OCI_RELAYPASSWORD $NOREPLY_PASSWORD $AWS_RELAYUSER $AWS_RELAYPASSWORD'

      echo "[init] Substituting secrets into mailu.env..."
      # Read .secrets safely (avoid shell interpretation of < > $ in values)
      while IFS='=' read -r _key _val; do
        case "$_key" in ""|\#*) continue ;; esac
        export "$_key=$_val"
      done < .secrets
      envsubst "$ENV_VARS" < mailu.env.tpl > mailu.env

      # Decode DKIM private key from base64 if present in .secrets
      if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
        echo "[init] Writing DKIM private key..."
        mkdir -p dkim
        echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > dkim/${config.domain}.dkim.key
        chmod 600 dkim/${config.domain}.dkim.key
      fi

      # Generate combined sasl_passwd for postfix (OCI primary + AWS fallback)
      if [ -n "$OCI_RELAYUSER" ] && [ -n "$AWS_RELAYUSER" ]; then
        echo "[init] Writing combined postfix sasl_passwd (OCI + AWS)..."
        mkdir -p overrides/postfix
        printf '[${config.oci_relay_host}]:${config.oci_relay_port} %s:%s\n[${config.aws_relay_host}]:${config.aws_relay_port} %s:%s\n' \
          "$OCI_RELAYUSER" "$OCI_RELAYPASSWORD" "$AWS_RELAYUSER" "$AWS_RELAYPASSWORD" \
          > overrides/postfix/sasl_multi_passwd
        chmod 600 overrides/postfix/sasl_multi_passwd
      fi

      echo "[init] Done."
    '';

    # Post-start setup: ensure exactly two accounts exist: me@ and no-reply@
    mkSetupSh = pkgs: pkgs.writeText "setup.sh" ''
      #!/bin/sh
      set -e
      cd "$(dirname "$0")"

      # Load secrets so NOREPLY_PASSWORD is available
      if [ -f .secrets ]; then
        while IFS='=' read -r _key _val; do
          case "$_key" in ""|\#*) continue ;; esac
          export "$_key=$_val"
        done < .secrets
      fi

      echo "[setup] Waiting for admin container..."
      sleep 5

      # Ensure no-reply@ user exists (used by Authelia for sending notifications)
      echo "[setup] Creating no-reply@ user..."
      docker exec mailu-admin-1 flask mailu user no-reply ${config.domain} "$NOREPLY_PASSWORD" 2>/dev/null || echo "[setup] no-reply@ already exists"

      # Remove stale admin@ account if it exists
      echo "[setup] Removing stale admin@ account..."
      docker exec mailu-admin-1 flask mailu user-delete admin ${config.domain} 2>/dev/null || echo "[setup] admin@ not found, skipping"

      echo "[setup] Done. Active accounts: me@ (superadmin), no-reply@ (SMTP sender)"
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
      defaultPkg = pkgs.runCommand "mailu-configs" {} ''
        mkdir -p $out/overrides/dovecot $out/overrides/roundcube $out/overrides/nginx $out/overrides/postfix $out/overrides/rspamd
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkMailuEnvTpl pkgs} $out/mailu.env.tpl
        cp ${mkInitSh pkgs} $out/init.sh
        chmod +x $out/init.sh
        cp ${mkSetupSh pkgs} $out/setup.sh
        chmod +x $out/setup.sh
        cp ${./overrides/dovecot/submission.conf} $out/overrides/dovecot/submission.conf
        cp ${./overrides/roundcube/calendar.inc.php} $out/overrides/roundcube/calendar.inc.php
        cp ${./overrides/roundcube/custom.inc.php} $out/overrides/roundcube/custom.inc.php
        cp ${./overrides/postfix/postfix.cf} $out/overrides/postfix/postfix.cf
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
