{
  description = "SnappyMail — Lightweight webmail client for Maddy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    lib = nixpkgs.lib;

    # base_domain derived from service domain: "webmail.example.com" → "example.com"
    base_domain = lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    config = {
      port = toString buildJson.ports.app;
      domain = base_domain;
      mail_domain = "mail.${base_domain}";
    };

    title = "SnappyMail";
    docker = import ../../_shared/docker.nix;

    # ── SnappyMail domain config (IMAP + SMTP to Maddy via mail FQDN) ──
    # ${config.mail_domain} resolves to 127.0.0.1 on the VM via /etc/hosts, so
    # PHP TLS verify_peer_name passes against the *.diegonmarcos.com wildcard cert.
    mkDomainConfig = pkgs: pkgs.writeText "${base_domain}.ini" ''
      imap_host = "${config.mail_domain}"
      imap_port = 993
      imap_secure = "SSL"
      imap_short_login = 0

      smtp_host = "${config.mail_domain}"
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
    # .secrets is shell-escaped (KEY='val') by the engine, so source it as bash
    # rather than parsing KEY=VALUE manually — otherwise the literal single
    # quotes leak into envsubst output and break password_verify().
    mkInitSh = pkgs: pkgs.writeText "init.sh" ''
      #!/usr/bin/env bash
      set -e
      cd "$(dirname "$0")"

      ENV_VARS='$SNAPPYMAIL_ADMIN_PASSWORD'

      echo "[init] Substituting secrets into application.ini..."
      set -a
      . ./.secrets
      set +a
      envsubst "$ENV_VARS" < config/application.ini.tpl > config/application.ini

      echo "[init] Done — configs mounted directly into container via named volume overlays."
    '';

    ghcr = docker.mkGhcrBuild {
      name = "snappymail";
      fromImage = buildJson.upstream_image;
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
          container_name = buildJson.containers.app.container_name;
          # host network: shares lo with co-located maddy (also host-mode) so
          # domain config can use imap_host=localhost. VM INPUT policy is DROP
          # except 10.0.0.0/24+lo, so :8888 stays reachable only via WG.
          networkMode = "host";
          skipReadOnly = true;
          volumes = [
            "snappymail_data:/var/lib/snappymail"
            "./config/application.ini:/opt/snappymail-config/application.ini:ro"
            "./config/domains:/var/lib/snappymail/_data_/_default_/domains"
          ];
          entrypoint = [ "/bin/sh" "-c" "cp -f /opt/snappymail-config/application.ini /var/lib/snappymail/_data_/_default_/configs/application.ini 2>/dev/null || true; exec /entrypoint.sh" ];
          allowWritableBindMounts = true;  # config overlay on named volume
          memLimit = buildJson.resources.mem_limit;
          memReservation = buildJson.resources.mem_reservation;
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
