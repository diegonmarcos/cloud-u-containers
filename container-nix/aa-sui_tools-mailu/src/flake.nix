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
      subnet = "192.168.203.0/24";

      # Message size limit (50MB)
      message_size_limit = "50000000";

      # Public IP (OCI micro)
      public_ip = "130.110.251.193";

      # Oracle Email Delivery relay
      relay_host = "smtp.email.eu-marseille-1.oci.oraclecloud.com";
      relay_port = "587";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        resolver:
          image: ghcr.io/mailu/unbound:2024.06
          env_file: mailu.env
          restart: always
          networks:
            default:
              ipv4_address: 192.168.203.254

        front:
          image: ghcr.io/mailu/nginx:2024.06
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
            - resolver
          dns:
            - 192.168.203.254

        admin:
          image: ghcr.io/mailu/admin:2024.06
          env_file: mailu.env
          restart: always
          volumes:
            - "./data:/data"
            - "./dkim:/dkim"
          depends_on:
            - resolver
            - redis
          dns:
            - 192.168.203.254

        imap:
          image: ghcr.io/mailu/dovecot:2024.06
          env_file: mailu.env
          restart: always
          volumes:
            - "./mail:/mail"
            - "./overrides/dovecot:/overrides:ro"
          depends_on:
            - resolver
            - front
          dns:
            - 192.168.203.254

        smtp:
          image: ghcr.io/mailu/postfix:2024.06
          env_file: mailu.env
          restart: always
          volumes:
            - "./mailqueue:/queue"
            - "./overrides/postfix:/overrides:ro"
          depends_on:
            - resolver
            - front
          dns:
            - 192.168.203.254

        antispam:
          image: ghcr.io/mailu/rspamd:2024.06
          env_file: mailu.env
          restart: always
          volumes:
            - "./filter:/var/lib/rspamd"
            - "./overrides/rspamd:/overrides:ro"
          depends_on:
            - resolver
            - front
          dns:
            - 192.168.203.254

        redis:
          image: redis:7-bookworm
          restart: always
          volumes:
            - "./redis:/data"

        webmail:
          image: ghcr.io/mailu/webmail:2024.06
          env_file: mailu.env
          restart: always
          volumes:
            - "./webmail:/data"
            - "./overrides/roundcube:/overrides:ro"
          depends_on:
            - resolver
            - front
            - imap
          dns:
            - 192.168.203.254

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
      HOSTNAMES=imap.${config.domain},smtp.${config.domain}
      POSTMASTER=admin

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

      RELAYHOST=[${config.relay_host}]:${config.relay_port}
      RELAYUSER=''\${RELAYUSER}
      RELAYPASSWORD=''\${RELAYPASSWORD}

      MESSAGE_SIZE_LIMIT=${config.message_size_limit}

      INITIAL_ADMIN_ACCOUNT=admin
      INITIAL_ADMIN_DOMAIN=${config.domain}
      INITIAL_ADMIN_PW=''\${INITIAL_ADMIN_PW}

      SITENAME=Diego Mail
      WEBSITE=https://${config.mail_domain}

      DB_FLAVOR=sqlite
      LOG_LEVEL=INFO
      CREDENTIAL_ROUNDS=12

      PUBLICIP=${config.public_ip}

      PROXY_AUTH_WHITELIST=35.226.147.64
      PROXY_AUTH_HEADER=X-Forwarded-User
      PROXY_AUTH_CREATE=False
    '';

    # Init script: sources .secrets, runs envsubst on template, decodes DKIM key
    mkInitSh = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e
      cd "$(dirname "$0")"

      ENV_VARS='$SECRET_KEY $INITIAL_ADMIN_PW $RELAYUSER $RELAYPASSWORD'

      echo "[init] Substituting secrets into mailu.env..."
      set -a; . ./.secrets; set +a
      envsubst "$ENV_VARS" < mailu.env.tpl > mailu.env

      # Decode DKIM private key from base64 if present in .secrets
      if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
        echo "[init] Writing DKIM private key..."
        mkdir -p dkim
        echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > dkim/${config.domain}.dkim.key
        chmod 600 dkim/${config.domain}.dkim.key
      fi

      echo "[init] Done."
    '';

    # Post-start setup: create aliases and users that must exist
    mkSetupSh = pkgs: pkgs.writeText "setup.sh" ''
      #!/bin/sh
      set -e
      echo "[setup] Waiting for admin container..."
      sleep 5

      echo "[setup] Creating no-reply alias..."
      docker exec mailu-admin-1 flask mailu alias no-reply ${config.domain} me@${config.domain} 2>/dev/null || echo "[setup] Alias already exists"

      echo "[setup] Done."
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "mailu-configs" {} ''
        mkdir -p $out/overrides/dovecot $out/overrides/roundcube $out/overrides/nginx $out/overrides/postfix $out/overrides/rspamd
        mkdir -p $out/certs
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkMailuEnvTpl pkgs} $out/mailu.env.tpl
        cp ${mkInitSh pkgs} $out/init.sh
        chmod +x $out/init.sh
        cp ${mkSetupSh pkgs} $out/setup.sh
        chmod +x $out/setup.sh
        cp ${./overrides/dovecot/submission.conf} $out/overrides/dovecot/submission.conf
        cp ${./overrides/roundcube/calendar.inc.php} $out/overrides/roundcube/calendar.inc.php
        ln -s letsencrypt/live/mailu/fullchain.pem $out/certs/cert.pem
        ln -s letsencrypt/live/mailu/privkey.pem $out/certs/key.pem
      '';
    });
  };
}
