{
  # Engine consolidation test 2026-04-15
  description = "Dagu - Lightweight DAG-based workflow scheduler";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    svc = (builtins.fromJSON (builtins.readFile ./cloud-data-service-connections.json)).services;

    config = {
      container_name = "dagu";
      image = "ghcr.io/diegonmarcos/dagu:latest";
      port = buildJson.ports.app;
      domain = buildJson.domain;
    };

    title = "Dagu - Lightweight DAG-based workflow scheduler";
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/bc-obs_dagu/src/flake.nix";
      volumes = {
        dagu_data = {};
      };
      services = {
        dagu = docker.mkService {
          name = "dagu";
          build = { context = "."; dockerfile = "Dockerfile"; };
          image = config.image;
          container_name = config.container_name;
          portEnv = ports.envFor "app";
          entrypoint = ["dagu" "start-all"];
          skipReadOnly = true;
          allowWritableBindMounts = true;
          environment = [
            "DAGU_HOST=${svc.dagu.ip}"
            "DAGU_DAGS_DIR=/var/lib/dagu/dags"
            "DAGU_BASE_CONFIG=/var/lib/dagu/base.yaml"
            "DAGU_AUTH_MODE=none"
            "DAGU_TZ=Europe/Berlin"
            "DAGU_NAVBAR_COLOR=#1a1a2e"
            "DAGU_NAVBAR_TITLE=C3 Workflows"
            "AUTHELIA_OIDC_CLIENT_ID=dagu-cc"
            "AUTHELIA_OIDC_CLIENT_SECRET=\${AUTHELIA_OIDC_DAGU_SECRET}"
            "AUTHELIA_TOKEN_URL=https://auth.diegonmarcos.com/api/oidc/token"
          ];
          env_file = [".secrets"];
          volumes = [
            "dagu_data:/var/lib/dagu/data"
            "./dags:/var/lib/dagu/dags"
            "./base.yaml:/var/lib/dagu/base.yaml:ro"
            "./fetch-token.sh:/var/lib/dagu/fetch-token.sh:ro"
            "/opt/ssh-keys/dagu:/home/dagu/.ssh:ro"
            "/var/run/docker.sock:/var/run/docker.sock"
          ];
          memLimit = "256m";
        };
      };
    };

    # ── Base config: SMTP + default notifications ────────────────────────
    mkBaseConfig = pkgs: pkgs.writeText "base.yaml" ''
      shell: /bin/bash

      smtp:
        host: 10.0.0.3
        port: "587"
        username: "no-reply@diegonmarcos.com"
        password: "$NOREPLY_PASSWORD"

      mail_on:
        failure: false
        success: false

      error_mail:
        from: no-reply@diegonmarcos.com
        to:
          - me@diegonmarcos.com
        prefix: "[Dagu FAIL]"
        attach_logs: true

      info_mail:
        from: no-reply@diegonmarcos.com
        to:
          - me@diegonmarcos.com
        prefix: "[Dagu OK]"
    '';

    # ── OIDC token fetch entrypoint ───────────────────────────────────────
    mkFetchToken = pkgs: pkgs.writeText "fetch-token.sh" ''
      #!/bin/sh

      # Fetch OIDC token via client_credentials grant, export as AUTHELIA_BEARER_TOKEN
      # so all existing DAG workflows keep working without changes.
      # Starts dagu regardless — token failure is non-fatal (DAGs using bearer will fail individually).
      echo "[fetch-token] Requesting OIDC token from $AUTHELIA_TOKEN_URL ..."
      RESPONSE=$(curl -s --max-time 10 -X POST "$AUTHELIA_TOKEN_URL" \
        -u "$AUTHELIA_OIDC_CLIENT_ID:$AUTHELIA_OIDC_CLIENT_SECRET" \
        -d "grant_type=client_credentials&scope=authelia.bearer.authz" 2>&1) || true

      TOKEN=$(echo "$RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      if [ -n "$TOKEN" ]; then
        export AUTHELIA_BEARER_TOKEN="$TOKEN"
        echo "[fetch-token] Token acquired (''${#TOKEN} chars)"
      else
        echo "[fetch-token] WARNING: Failed to get OIDC token — dagu will start without bearer auth"
        echo "[fetch-token] Response: $RESPONSE"
      fi

      # Start ntfy→dagu WebSocket bridge in background
      ntfy-bridge.sh &

      exec dagu start-all
    '';

    # ── SSH shorthand used across all workflows ──────────────────────────
    sshCmd = "ssh -i /home/dagu/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR";
    # VM list derived from monitoring-targets.json at runtime
    monTargets = "/var/lib/dagu/data/cloud-data/cloud-data-monitoring-targets.json";
    vmListCmd = ''
      jq -r '.vms[] | "\(.ip):\(.name):\(.user)"' "${monTargets}" | tr '\n' ' '
    '';

    # ── DAG workflows ────────────────────────────────────────────────────
    # DAGs live in src/dags/*.yaml (file-based, not inline Nix).
    # The flake copies them to dist/dags/ via: cp -r ${./dags}/. $out/dags/
    # This keeps DAGs portable — same files work in Dagu, CLI, or any runner.
    # Old inline mkDags (1730 lines) removed — see git history.


  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "dagu-configs" {} ''
        mkdir -p $out/dags
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkBaseConfig pkgs} $out/base.yaml
        cp ${mkFetchToken pkgs} $out/fetch-token.sh
        chmod +x $out/fetch-token.sh
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./triggers.json} $out/triggers.json
        cp ${./ntfy-bridge.sh} $out/ntfy-bridge.sh
        chmod +x $out/ntfy-bridge.sh
        cp -r ${./dags}/. $out/dags/
        # report_daily.sh moved to cloud-data/reports/cloud-health-daily-mail/src/
        chmod +x $out/dags/gha/*.sh 2>/dev/null || true
        # Prevent Dagu from overwriting our DAGs with example files on first start
        touch $out/dags/.examples-created
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; docsPath = ./docs; };
    });
  };
}
