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
      entrypoint = [ "dagu" "start-all" ];
      env_file = [ ".secrets" ];
      environment = [
        "DAGU_HOST=${svc.dagu.ip}"
        "DAGU_DAGS_DIR=/var/lib/dagu/dags"
        "DAGU_BASE_CONFIG=/var/lib/dagu/base.yaml"
        # SSO (#1147): "none" until the sso-oidc-issue bundle delivers DAGU_AUTH_MODE=oidc
        # together with DAGU_OIDC_CLIENT_SECRET. The edge gate (2FA) stays in front either way.
        "DAGU_AUTH_MODE=\${DAGU_AUTH_MODE:-none}"
        "DAGU_AUTH_OIDC_ISSUER=https://sso.diegonmarcos.com"
        "DAGU_AUTH_OIDC_CLIENT_ID=dagu-ui"
        "DAGU_AUTH_OIDC_CLIENT_SECRET=\${DAGU_OIDC_CLIENT_SECRET:-}"
        "DAGU_AUTH_OIDC_CLIENT_URL=https://workflows.diegonmarcos.com"
        "DAGU_AUTH_OIDC_SCOPES=openid,profile,email"
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
        "octocode_repos:/var/lib/dagu/data/repos"
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
    octocode_repos = { name = "octocode_repos"; };
  };
}
