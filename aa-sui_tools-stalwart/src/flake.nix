{
  description = "Stalwart Mail Server v0.13 — SHADOW MODE (JMAP/Sieve testing, offset ports)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    title = "Stalwart Mail Server (Shadow)";
    docker = import ../../_shared/docker.nix;

    # Admin password hash (SHA-512 crypt) — generated from secrets, baked into config
    # This is a HASH, not the plaintext password — safe to include in config
    # Note: '' escapes ${ in nix strings
    adminHash = "$6$StalwartShadow$TnGwCZsckFjb/S6BcJV5UL8Gxf25mlA4eO2WI1G7jDYCwdMTfeSQUAUcR2H6mujyRMTjAWMHf3SyRNW/3.r7a/";

    # GHCR image: wrap upstream with config
    ghcr = docker.mkGhcrBuild {
      name = "stalwart";
      fromImage = "stalwartlabs/stalwart:v0.13";
      configFiles = [
        { src = "config.toml"; dst = "/opt/stalwart-mail/etc/config.toml"; }
      ];
    };

    # ── Config: substitute admin hash ──────────────────────────────────
    # Use printf + awk to avoid shell $ interpretation in the hash
    mkConfig = pkgs: pkgs.runCommand "config.toml" {
      hash = adminHash;
    } ''
      ${pkgs.gawk}/bin/awk -v h="$hash" '{gsub(/@@ADMIN_HASH@@/, h); print}' ${./config.toml.tpl} > $out
    '';

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
          entrypoint = ["stalwart" "--config" "/opt/stalwart-mail/etc/config.toml"];
          skipCapDrop = true;
          skipReadOnly = true;
          environment = [
            "TZ=Europe/Madrid"
          ];
          volumes = [
            "stalwart_data:/opt/stalwart-mail/data"
            "/opt/containers/maddy/tls:/opt/stalwart-mail/tls:ro"
            "./config.toml:/opt/stalwart-mail/etc/config.toml:ro"
          ];
          memLimit = "256M";
          memReservation = "32M";
        };
      };
    };

    # ── Activation script: ensure accounts exist after deploy ────────
    # Runs after compose-up. Idempotent — fieldAlreadyExists is fine.
    # Reads ADMIN_PASSWORD from .secrets to authenticate.
    mkActivate = pkgs: pkgs.writeText "activate.sh" ''
      #!/bin/sh
      set -e
      URL="https://localhost:${toString (ports.valueOf "app")}/api/principal"
      PW=$(cat /opt/containers/stalwart/.secrets.d/ADMIN_PASSWORD 2>/dev/null)
      [ -z "$PW" ] && echo "[activate] No ADMIN_PASSWORD found, skipping" && exit 0

      echo "[activate] Waiting for Stalwart to start..."
      for i in $(seq 1 30); do
        curl -sk -u "admin:$PW" "$URL" -o /dev/null 2>/dev/null && break
        sleep 2
      done

      echo "[activate] Ensuring domain + accounts..."
      curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
        -d '{"type":"domain","name":"diegonmarcos.com"}' 2>/dev/null || true

      curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
        -d '{"type":"individual","name":"me@diegonmarcos.com","secrets":["'"$PW"'"],"emails":["me@diegonmarcos.com"],"roles":["admin"]}' 2>/dev/null || true

      NR_PW=$(cat /opt/containers/stalwart/.secrets.d/NOREPLY_PASSWORD 2>/dev/null || echo "noreply")
      curl -sk -u "admin:$PW" -X POST "$URL" -H "Content-Type: application/json" \
        -d '{"type":"individual","name":"no-reply@diegonmarcos.com","secrets":["'"$NR_PW"'"],"emails":["no-reply@diegonmarcos.com","noreply@diegonmarcos.com"],"roles":["user"]}' 2>/dev/null || true

      echo "[activate] Done — accounts ensured"
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "stalwart-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkConfig pkgs} $out/config.toml
        cp ${mkActivate pkgs} $out/activate.sh
        chmod +x $out/activate.sh
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title; config = {}; inherit defaultPkg; };
    });
  };
}
