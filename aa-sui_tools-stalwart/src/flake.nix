{
  description = "Stalwart Mail Server — SHADOW MODE (JMAP/Sieve testing, offset ports)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      domain = "diegonmarcos.com";
      mail_domain = buildJson.domain;
      timezone = "Europe/Madrid";
      message_size_limit = "52428800";  # 50MB

      # Web admin port (from build.json — 2443 in shadow mode)
      port = buildJson.ports.app;
    };

    title = "Stalwart Mail Server (Shadow)";
    docker = import ../../_shared/docker.nix;

    # GHCR image: bake config template + init script into image
    # init.sh substitutes secrets and decodes DKIM key at container start
    ghcr = docker.mkGhcrBuild {
      name = "stalwart";
      fromImage = "stalwartlabs/mail-server:v0.11";
      configFiles = [
        { src = "config.toml.tpl"; dst = "/opt/stalwart-mail/etc/config.toml.tpl"; }
        { src = "init.sh"; dst = "/opt/stalwart-mail/init.sh"; }
      ];
      extraDockerfileLines = [
        "RUN apt-get update && apt-get install -y --no-install-recommends gettext-base curl && rm -rf /var/lib/apt/lists/*"
      ];
    };

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/aa-sui_tools-stalwart/src/flake.nix";
      volumes = {
        stalwart_data = {};
      };
      services = {
        stalwart = docker.mkService {
          name = "stalwart";
          image = ghcr.image;
          build = ghcr.build;
          container_name = "stalwart";
          entrypoint = ["sh" "/opt/stalwart-mail/init.sh"];
          env_file = [".secrets"];
          skipCapDrop = true;
          skipReadOnly = true;
          environment = [
            "TZ=${config.timezone}"
          ];
          volumes = [
            "stalwart_data:/opt/stalwart-mail/data"
            "./tls:/opt/stalwart-mail/tls:ro"
          ];
          memLimit = "256M";
          memReservation = "32M";
        };
      };
    };

    # ── Stalwart config.toml template ──────────────────────────────────
    # Source: src/config.toml.tpl (standalone file — no nix escaping needed)
    # @@PLACEHOLDERS@@ substituted by nix, ${SECRETS} by init.sh at runtime
    mkConfigToml = pkgs: pkgs.runCommand "config.toml.tpl" {} ''
      substitute ${./config.toml.tpl} $out \
        --replace-fail "@@DOMAIN@@" "${config.domain}" \
        --replace-fail "@@MAIL_DOMAIN@@" "${config.mail_domain}" \
        --replace-fail "@@PORT@@" "${toString config.port}" \
        --replace-fail "@@MESSAGE_SIZE_LIMIT@@" "${config.message_size_limit}"
    '';

    # ── Init script ────────────────────────────────────────────────────
    mkInitSh = pkgs: pkgs.writeText "init.sh" ''
      #!/bin/sh
      set -e

      ENV_VARS='$ADMIN_PASSWORD $ME_PASSWORD $NOREPLY_PASSWORD $DKIM_PRIVATE_KEY_B64'

      echo "[init] Substituting secrets into config.toml..."
      envsubst "$ENV_VARS" < /opt/stalwart-mail/etc/config.toml.tpl > /opt/stalwart-mail/etc/config.toml

      # Decode DKIM private key from base64
      if [ -n "$DKIM_PRIVATE_KEY_B64" ]; then
        echo "[init] Writing DKIM private key..."
        mkdir -p /opt/stalwart-mail/dkim
        echo "$DKIM_PRIVATE_KEY_B64" | base64 -d > /opt/stalwart-mail/dkim/${config.domain}.dkim.key
        chmod 600 /opt/stalwart-mail/dkim/${config.domain}.dkim.key
      fi

      # Auto-create domain + user principals in internal directory (RocksDB may be wiped)
      # Background task: wait for Stalwart to start, then ensure all principals exist
      (sleep 10 && AUTH="admin@${config.domain}:$ADMIN_PASSWORD" && \
        curl -sk -X POST "https://localhost:${toString config.port}/api/principal" \
          -u "$AUTH" -H "Content-Type: application/json" \
          -d '{"type":"domain","name":"${config.domain}"}' 2>/dev/null && \
        curl -sk -X POST "https://localhost:${toString config.port}/api/principal" \
          -u "$AUTH" -H "Content-Type: application/json" \
          -d '{"type":"individual","name":"me@${config.domain}","secrets":["'"$ME_PASSWORD"'"],"emails":["me@${config.domain}"],"roles":["user"]}' 2>/dev/null && \
        curl -sk -X POST "https://localhost:${toString config.port}/api/principal" \
          -u "$AUTH" -H "Content-Type: application/json" \
          -d '{"type":"individual","name":"no-reply@${config.domain}","secrets":["'"$NOREPLY_PASSWORD"'"],"emails":["no-reply@${config.domain}","noreply@${config.domain}"],"roles":["user"]}' 2>/dev/null && \
        echo "[init] All principals ensured in internal directory" || true) &

      echo "[init] Starting Stalwart..."
      exec /usr/local/bin/stalwart-mail --config /opt/stalwart-mail/etc/config.toml
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
