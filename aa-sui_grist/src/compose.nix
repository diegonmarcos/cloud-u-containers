# compose.nix — pure attrset describing docker-compose.yml for grist.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    grist = {
      image = binariesImage;
      container_name = app.container_name;
      environment = {
        PORT               = toString buildJson.ports.app;
        GRIST_SESSION_SECRET = "changeme-secret-key";
        GRIST_SINGLE_ORG     = "docs";
        GRIST_DEFAULT_EMAIL  = "\${GRIST_ADMIN_EMAIL:-${buildJson.grist_admin_email}}";
        APP_HOME_URL         = "https://${buildJson.domain}";
        GRIST_SANDBOX_FLAVOR = "unsandboxed";
        GRIST_LOG_LEVEL      = "info";
      };
      ports = [
        "${toString buildJson.ports.app}:${toString buildJson.ports.app}"
      ];
      volumes = [
        "grist_data:/persist"
      ];
      healthcheck = {
        test = [ "CMD" "curl" "-f" "http://localhost:${toString buildJson.ports.app}/" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
    };
  };
  volumes = {
    grist_data = {};
  };
}
