# compose.nix — docker-compose spec for dagu (DAG-based workflow scheduler).
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service. Paths are relative to dist/
# (docker-compose project-directory at deploy time).
{ buildJson, container, svc }:

let
  app = buildJson.containers.app;
  # Own-code: pull the engine-built+pushed image (real Dockerfile, native arch
  # per deploy host) — matches every other own-code service (dbgate/kg-store/…).
  # NO compose-side `build:` — that re-used a stale amd64 dagu:latest and never
  # rebuilt on the aarch64 host. The engine builds ghcr.io/…/dagu-binaries:latest.
  image = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    dagu = {
      image = image;
      container_name = app.container_name;
      network_mode = "host";
      # ponytail: diagnostic wrapper — captures crash output, keeps container alive 600s
      entrypoint = [ "/bin/sh" "-c" "dagu start-all 2>&1; echo \"DAGU_EXIT=$?\"; sleep 600" ];
      env_file = [ ".secrets" ];
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
        "DAGU_PORT=${toString buildJson.ports.app}"
      ];
      volumes = [
        "dagu_data:/var/lib/dagu/data"
        "./assets/dags:/var/lib/dagu/dags"
        "./configs/base.yaml:/var/lib/dagu/base.yaml:ro"
        "./configs/fetch-token.sh:/var/lib/dagu/fetch-token.sh:ro"
        "/opt/ssh-keys/dagu:/home/dagu/.ssh:ro"
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
      deploy.resources = {
        limits       = { memory = "256m"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };
  };
  volumes = {
    dagu_data = {};
  };
}
