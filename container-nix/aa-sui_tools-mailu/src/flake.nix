{
  description = "Mailu Mail Server - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "diegonmarcos.com";
      mail_domain = "mail.diegonmarcos.com";
      hostname = "mail";
      timezone = "Europe/Madrid";
      secret_key = "CHANGE_ME_SECRET_KEY";

      # Subnet for Mailu internal network
      subnet = "192.168.203.0/24";

      # Admin
      admin_email = "admin@diegonmarcos.com";
      admin_password = "CHANGE_ME_ADMIN_PASSWORD";

      # Message size limit (50MB)
      message_size_limit = "50000000";

      # Oracle Email Delivery relay
      relay_host = "smtp.email.eu-marseille-1.oci.oraclecloud.com";
      relay_port = "587";
      relay_user = "CHANGE_ME_RELAY_USER";
      relay_password = "CHANGE_ME_RELAY_PASSWORD";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      

      services:
        # Reverse proxy and HTTPS termination
        front:
          image: ghcr.io/mailu/nginx:2024.06
          container_name: mailu-front
          restart: unless-stopped
          env_file: mailu.env
          logging:
            driver: journald
            options:
              tag: mailu-front
          ports:
            - "80:80"
            - "443:443"
            - "25:25"
            - "465:465"
            - "993:993"
          volumes:
            - ./certs:/certs
            - ./overrides/nginx:/overrides:ro
          networks:
            - default
            - proxy

        # Admin interface
        admin:
          image: ghcr.io/mailu/admin:2024.06
          container_name: mailu-admin
          restart: unless-stopped
          env_file: mailu.env
          logging:
            driver: journald
            options:
              tag: mailu-admin
          volumes:
            - ./data:/data
            - ./dkim:/dkim
          depends_on:
            - redis
          networks:
            - default

        # IMAP server
        imap:
          image: ghcr.io/mailu/dovecot:2024.06
          container_name: mailu-imap
          restart: unless-stopped
          env_file: mailu.env
          logging:
            driver: journald
            options:
              tag: mailu-imap
          volumes:
            - ./mail:/mail
            - ./overrides/dovecot:/overrides:ro
          depends_on:
            - front
          networks:
            - default

        # SMTP server
        smtp:
          image: ghcr.io/mailu/postfix:2024.06
          container_name: mailu-smtp
          restart: unless-stopped
          env_file: mailu.env
          logging:
            driver: journald
            options:
              tag: mailu-smtp
          volumes:
            - ./mailqueue:/queue
            - ./overrides/postfix:/overrides:ro
          depends_on:
            - front
          networks:
            - default

        # Antispam
        antispam:
          image: ghcr.io/mailu/rspamd:2024.06
          container_name: mailu-antispam
          restart: unless-stopped
          env_file: mailu.env
          logging:
            driver: journald
            options:
              tag: mailu-antispam
          volumes:
            - ./filter:/var/lib/rspamd
            - ./overrides/rspamd:/overrides:ro
          depends_on:
            - front
          networks:
            - default

        # Webmail (Roundcube)
        webmail:
          image: ghcr.io/mailu/webmail:2024.06
          container_name: mailu-webmail
          restart: unless-stopped
          env_file: mailu.env
          logging:
            driver: journald
            options:
              tag: mailu-webmail
          volumes:
            - ./webmail:/data
            - ./overrides/roundcube:/overrides:ro
          depends_on:
            - front
          networks:
            - default

        # Redis for session storage
        redis:
          image: redis:7-bookworm
          container_name: mailu-redis
          restart: unless-stopped
          volumes:
            - ./redis:/data
          networks:
            - default

        # DNS resolver
        resolver:
          image: ghcr.io/mailu/unbound:2024.06
          container_name: mailu-resolver
          restart: unless-stopped
          env_file: mailu.env
          networks:
            default:
              ipv4_address: 192.168.203.254

      networks:
        default:
          driver: bridge
          ipam:
            config:
              - subnet: ${config.subnet}
        proxy:
          external: true
    '';

    mkMailuEnv = pkgs: pkgs.writeText "mailu.env" ''
      # Mailu configuration
      SECRET_KEY=${config.secret_key}
      DOMAIN=${config.domain}
      HOSTNAMES=${config.mail_domain}

      # Postmaster
      POSTMASTER=admin

      # TLS
      TLS_FLAVOR=letsencrypt

      # Authentication
      AUTH_RATELIMIT_IP=60/hour
      AUTH_RATELIMIT_USER=100/day

      # Admin
      ADMIN=true
      WEBMAIL=roundcube

      # Limits
      MESSAGE_SIZE_LIMIT=${config.message_size_limit}

      # Logging
      LOG_LEVEL=INFO

      # Network
      SUBNET=${config.subnet}

      # Relay (Oracle Email Delivery)
      RELAYHOST=${config.relay_host}
      RELAY_PORT=${config.relay_port}
      RELAY_USER=${config.relay_user}
      RELAY_PASSWORD=${config.relay_password}

      # Timezone
      TZ=${config.timezone}

      # Resolver
      RESOLVER=192.168.203.254
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "mailu-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        mkdir -p $out/overrides/dovecot
        mkdir -p $out/overrides/roundcube
        cp ${./overrides/dovecot/submission.conf} $out/overrides/dovecot/submission.conf
        cp ${./overrides/roundcube/calendar.inc.php} $out/overrides/roundcube/calendar.inc.php
      '';
    });
  };
}
