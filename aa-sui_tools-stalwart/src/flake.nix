{
  description = "Stalwart Mail Server - All-in-one mail (IMAP/SMTP/JMAP/Sieve/spam/DKIM)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "diegonmarcos.com";
      mail_domain = "mail.diegonmarcos.com";
      timezone = "Europe/Madrid";
      message_size_limit = "52428800";  # 50MB

      # OCI Email Delivery relay (primary)
      oci_relay_host = "smtp.email.eu-marseille-1.oci.oraclecloud.com";
      oci_relay_port = "587";

      # AWS SES relay (fallback)
      aws_relay_host = "email-smtp.us-east-1.amazonaws.com";
      aws_relay_port = "587";
    };

    title = "Stalwart Mail Server";
    docker = import ../../_shared/docker.nix;

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/flake.nix";
      services = {
        stalwart = docker.mkService {
          name = "stalwart";
          image = "stalwartlabs/mail-server:v0.11";
          container_name = "stalwart";
          skipCapDrop = true;
          skipReadOnly = true;
          environment = [
            "TZ=${config.timezone}"
          ];
          volumes = [
            "./data:/opt/stalwart-mail/data"
            "./config.toml:/opt/stalwart-mail/etc/config.toml:ro"
            "./dkim:/opt/stalwart-mail/dkim:ro"
          ];
          memLimit = "512M";
          memReservation = "64M";
        };
      };
    };

    # ── Stalwart config.toml template ──────────────────────────────────
    # Secrets use ''${PLACEHOLDER} — substituted by init.sh from .secrets
    mkConfigToml = pkgs: pkgs.writeText "config.toml.tpl" ''
      # ╔══════════════════════════════════════════════════════════════════╗
      # ║ Stalwart Mail Server — declarative config (nix-generated)      ║
      # ║ Secrets substituted at deploy time by init.sh from .secrets    ║
      # ║ Source: ~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/     ║
      # ╚══════════════════════════════════════════════════════════════════╝

      # ── Server ──────────────────────────────────────────────────────
      [server]
      hostname = "${config.mail_domain}"
      max-connections = 512

      # ── Listeners ───────────────────────────────────────────────────
      [server.listener."smtp"]
      bind = ["0.0.0.0:25"]
      protocol = "smtp"

      [server.listener."submissions"]
      bind = ["0.0.0.0:465"]
      protocol = "smtp"
      tls.implicit = true

      [server.listener."submission"]
      bind = ["0.0.0.0:587"]
      protocol = "smtp"

      [server.listener."imaptls"]
      bind = ["0.0.0.0:993"]
      protocol = "imap"
      tls.implicit = true

      [server.listener."sieve"]
      bind = ["0.0.0.0:4190"]
      protocol = "managesieve"

      [server.listener."https"]
      bind = ["0.0.0.0:8443"]
      protocol = "http"
      tls.implicit = true

      # ── TLS (ACME — Let's Encrypt via Cloudflare DNS-01) ────────────
      [acme."letsencrypt"]
      directory = "https://acme-v02.api.letsencrypt.org/directory"
      contact = ["mailto:me@${config.domain}"]
      domains = ["${config.mail_domain}"]
      challenge = "dns-01"
      renew-before = "30d"

      [acme."letsencrypt".dns]
      provider = "cloudflare"
      secret = "''\${CF_DNS_API_TOKEN}"

      # ── Local domain — accept mail for diegonmarcos.com ─────────────
      [session.rcpt]
      relay = false
      directory = "static"

      [session.rcpt.domain]
      "${config.domain}" = true

      # ── Storage (RocksDB + filesystem) ──────────────────────────────
      [store."rocksdb"]
      type = "rocksdb"
      path = "/opt/stalwart-mail/data/db"

      [store."blob"]
      type = "fs"
      path = "/opt/stalwart-mail/data/blobs"

      [storage]
      data = "rocksdb"
      blob = "blob"
      fts = "rocksdb"
      lookup = "rocksdb"
      directory = "static"

      # ── Directory (static accounts — fully declarative) ─────────────
      [directory."static"]
      type = "memory"

      [[directory."static".principals]]
      type = "admin"
      name = "admin"
      secret = "''\${ADMIN_PASSWORD}"
      emails = ["admin@${config.domain}"]

      [[directory."static".principals]]
      type = "individual"
      name = "me"
      secret = "''\${ME_PASSWORD}"
      emails = ["me@${config.domain}"]

      [[directory."static".principals]]
      type = "individual"
      name = "no-reply"
      secret = "''\${NOREPLY_PASSWORD}"
      emails = ["no-reply@${config.domain}", "noreply@${config.domain}"]

      # ── Authentication ──────────────────────────────────────────────
      [authentication]
      fallback-admin.user = "admin"
      fallback-admin.secret = "''\${ADMIN_PASSWORD}"

      [session.auth]
      mechanisms = ["PLAIN", "LOGIN"]
      directory = "static"

      # ── DKIM signing ────────────────────────────────────────────────
      [signature."dkim"]
      private-key = "%{file:/opt/stalwart-mail/dkim/${config.domain}.dkim.key}%"
      domain = "${config.domain}"
      selector = "dkim"
      headers = ["From", "To", "Date", "Subject", "Message-ID"]
      algorithm = "rsa-sha256"
      canonicalization = "relaxed/relaxed"
      set-body-length = false
      report = true

      # ── Outbound relay (OCI primary → AWS fallback) ─────────────────
      [remote."oci-relay"]
      address = "${config.oci_relay_host}"
      port = ${config.oci_relay_port}
      protocol = "smtp"
      tls.start-tls = true

      [remote."oci-relay".auth]
      username = "''\${OCI_RELAYUSER}"
      password = "''\${OCI_RELAYPASSWORD}"

      [remote."aws-relay"]
      address = "${config.aws_relay_host}"
      port = ${config.aws_relay_port}
      protocol = "smtp"
      tls.start-tls = true

      [remote."aws-relay".auth]
      username = "''\${AWS_RELAYUSER}"
      password = "''\${AWS_RELAYPASSWORD}"

      [queue.outbound]
      next-hop = ["oci-relay", "aws-relay"]

      # ── Spam filter (built-in) ──────────────────────────────────────
      [spam.header]
      is-spam = "X-Spam-Status: Yes"

      # ── Message limits ──────────────────────────────────────────────
      [session.data.limits]
      size = ${config.message_size_limit}

      # ── Logging ─────────────────────────────────────────────────────
      [tracing."stdout"]
      type = "stdout"
      level = "info"
      enable = true
    '';

    # ── Init script ────────────────────────────────────────────────────
    mkInitSh = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e
      cd "$(dirname "$0")"

      # Stop Mailu if still running (migration from Mailu → Stalwart)
      if [ -f /opt/mailu/docker-compose.yml ]; then
        echo "[init] Stopping Mailu (migration to Stalwart)..."
        (cd /opt/mailu && docker compose down 2>/dev/null) || true
      fi

      ENV_VARS='$ADMIN_PASSWORD $ME_PASSWORD $NOREPLY_PASSWORD $OCI_RELAYUSER $OCI_RELAYPASSWORD $AWS_RELAYUSER $AWS_RELAYPASSWORD $DKIM_PRIVATE_KEY_B64 $CF_DNS_API_TOKEN'

      echo "[init] Substituting secrets into config.toml..."
      while IFS='=' read -r _key _val; do
        case "$_key" in ""|\#*) continue ;; esac
        export "$_key=$_val"
      done < .secrets
      envsubst "$ENV_VARS" < config.toml.tpl > config.toml

      # Decode DKIM private key from base64
      if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
        echo "[init] Writing DKIM private key..."
        mkdir -p dkim
        echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > dkim/${config.domain}.dkim.key
        chmod 600 dkim/${config.domain}.dkim.key
      fi

      # Ensure data directory exists
      mkdir -p data/db data/blobs data/acme

      echo "[init] Done."
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "stalwart-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkConfigToml pkgs} $out/config.toml.tpl
        cp ${mkInitSh pkgs} $out/init.sh
        chmod +x $out/init.sh
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
