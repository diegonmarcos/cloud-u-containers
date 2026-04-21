{
  # Engine consolidation test 2026-04-15
  description = "Maddy Mail Server - declarative all-in-one SMTP/IMAP (Go)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    buildContainer = builtins.fromJSON (builtins.readFile ./build-maddy.json);
    lib = nixpkgs.lib;

    # base_domain derived from service domain: "mail.example.com" → "example.com"
    base_domain = lib.concatStringsSep "." (lib.drop 1 (lib.splitString "." buildJson.domain));

    config = {
      domain = base_domain;
      mail_domain = buildJson.domain;
      oci_relay_host = buildJson.oci_relay.host;
      oci_relay_port = buildJson.oci_relay.port;
    };

    title = "Maddy Mail Server";
    docker = import ../../_shared/docker.nix;

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/aa-sui_tools-maddy/src/flake.nix";
      volumes = {
        maddy_data = {};
      };
      services = {
        maddy = docker.mkService {
          name = "maddy";
          image = buildJson.containers.app.image;
          container_name = buildContainer.container.container_name;
          entrypoint = ["sh" "/etc/maddy/init.sh"];
          env_file = [".secrets"];
          skipCapDrop = true;
          skipReadOnly = true;
          volumes = [
            "maddy_data:/data"
            "./maddy.conf.tpl:/etc/maddy/maddy.conf.tpl:ro"
            "./init.sh:/etc/maddy/init.sh:ro"
            "./tls:/data/tls:ro"
            # Delivery-time filter: Maddy forks this per incoming message via
            # imap.filter.command (see maddy.conf.tpl). mail-rules.json is the
            # declarative single source of truth for routing + tag flags.
            "./mail-rules.json:/data/mail-rules.json:ro"
            "./mail-filter.py:/usr/local/bin/mail-filter:ro"
          ];
          memLimit = buildJson.containers.app.resources.limits.memory;
          memReservation = buildJson.containers.app.resources.reservations.memory;
        };
      };
    };

    # ── Maddy config template ──────────────────────────────────────────
    mkMaddyConf = pkgs: pkgs.runCommand "maddy.conf.tpl" {} ''
      substitute ${./maddy.conf.tpl} $out \
        --replace-fail "@@DOMAIN@@" "${config.domain}" \
        --replace-fail "@@MAIL_DOMAIN@@" "${config.mail_domain}" \
        --replace-fail "@@OCI_RELAY_HOST@@" "${config.oci_relay_host}" \
        --replace-fail "@@OCI_RELAY_PORT@@" "${config.oci_relay_port}"
    '';

    # ── Init script ────────────────────────────────────────────────────
    mkInitSh = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e

      echo "[init] Generating maddy.conf from template..."
      cp /etc/maddy/maddy.conf.tpl /data/maddy.conf

      # Substitute relay secrets
      sed -i "s|\''${OCI_RELAYUSER}|$OCI_RELAYUSER|g" /data/maddy.conf
      sed -i "s|\''${OCI_RELAYPASSWORD}|$OCI_RELAYPASSWORD|g" /data/maddy.conf

      # Write DKIM private key from base64
      if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
        echo "[init] Writing DKIM key..."
        mkdir -p /data/dkim
        echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > /data/dkim/${config.domain}.key
        chmod 600 /data/dkim/${config.domain}.key
      fi

      # Create accounts (idempotent — errors ignored if already exist)
      echo "[init] Ensuring accounts..."
      echo "$ME_PASSWORD" | maddy creds create me@${config.domain} 2>/dev/null || true
      echo "$NOREPLY_PASSWORD" | maddy creds create no-reply@${config.domain} 2>/dev/null || true
      maddy imap-acct create me@${config.domain} 2>/dev/null || true
      maddy imap-acct create no-reply@${config.domain} 2>/dev/null || true

      echo "[init] Starting Maddy..."
      exec maddy -config /data/maddy.conf run
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "maddy-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkMaddyConf pkgs} $out/maddy.conf.tpl
        cp ${mkInitSh pkgs} $out/init.sh
        cp ${./mail-filter.py} $out/mail-filter.py
        cp ${./mail-rules.json} $out/mail-rules.json
        chmod +x $out/init.sh $out/mail-filter.py
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
