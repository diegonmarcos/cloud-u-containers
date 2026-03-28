{
  description = "SnappyMail — Lightweight webmail client for Stalwart";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      port = toString buildJson.ports.app;
      domain = "diegonmarcos.com";
      mail_domain = "mail.diegonmarcos.com";
    };

    title = "SnappyMail";
    docker = import ../../_shared/docker.nix;

    # ── SnappyMail domain config (IMAP + SMTP to Stalwart on localhost) ──
    mkDomainConfig = pkgs: pkgs.writeText "diegonmarcos.com.ini" ''
      imap_host = "localhost"
      imap_port = 993
      imap_secure = "SSL"
      imap_short_login = 0

      sieve_host = "localhost"
      sieve_port = 4190
      sieve_secure = "None"

      smtp_host = "localhost"
      smtp_port = 465
      smtp_secure = "SSL"
      smtp_short_login = 0
      smtp_auth = 1
      smtp_set_sender = 0

      white_list = ""
    '';

    # ── SnappyMail application config (template — secrets substituted by init.sh) ──
    mkAppConfigTpl = pkgs: pkgs.writeText "application.ini.tpl" ''
      [webmail]
      title = "Diego Mail"
      loading_description = "Diego Mail"
      theme = "Default"
      allow_languages_on_login = 1
      allow_additional_accounts = 0
      allow_additional_identities = 0

      [interface]
      show_attachment_thumbnail = 1

      [contacts]
      enable = 0

      [security]
      admin_password = "''\${SNAPPYMAIL_ADMIN_PASSWORD}"
      admin_totp = ""
      allow_admin_panel = 1
      csrf_protection = 1

      [login]
      default_domain = "${config.domain}"
      allow_languages_on_login = 1

      [plugins]
      enable = 0
    '';

    # ── Init script (substitutes secrets into config templates) ──────────
    mkInitSh = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e
      cd "$(dirname "$0")"

      ENV_VARS='$SNAPPYMAIL_ADMIN_PASSWORD'

      echo "[init] Substituting secrets into application.ini..."
      while IFS='=' read -r _key _val; do
        case "$_key" in ""|\#*) continue ;; esac
        export "$_key=$_val"
      done < .secrets
      envsubst "$ENV_VARS" < config/application.ini.tpl > config/application.ini

      echo "[init] Done — configs mounted directly into container via named volume overlays."
    '';

    ghcr = docker.mkGhcrBuild {
      name = "snappymail";
      fromImage = "djmaze/snappymail:latest";
    };

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/aa-sui_snappymail/src/flake.nix";
      volumes = {
        snappymail_data = {};
      };
      services = {
        snappymail = docker.mkService {
          name = "snappymail";
          image = ghcr.image;
          build = ghcr.build;
          container_name = "snappymail";
          skipReadOnly = true;
          volumes = [
            "snappymail_data:/var/lib/snappymail"
            "./config/application.ini:/opt/snappymail-config/application.ini:ro"
            "./config/domains:/var/lib/snappymail/_data_/_default_/domains"
          ];
          entrypoint = [ "/bin/sh" "-c" "cp -f /opt/snappymail-config/application.ini /var/lib/snappymail/_data_/_default_/configs/application.ini 2>/dev/null || true; exec /entrypoint.sh" ];
          allowWritableBindMounts = true;  # config overlay on named volume
          memLimit = "64M";
          memReservation = "16M";
          healthcheck = {
            test = "['CMD', 'curl', '-sf', 'http://localhost:${config.port}/']";
            interval = "30s";
            timeout = "10s";
            retries = 3;
            start_period = "10s";
          };
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "snappymail-configs" {} ''
        mkdir -p $out/config/domains
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkDomainConfig pkgs} $out/config/domains/${config.domain}.ini
        cp ${mkAppConfigTpl pkgs} $out/config/application.ini.tpl
        cp ${mkInitSh pkgs} $out/init.sh
        chmod +x $out/init.sh
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
