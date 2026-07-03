# compose.nix — docker-compose spec for google-workspace-mcp (Type A own-code, Python)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."google-workspace-mcp".ip or "10.0.0.6";
  port = toString buildJson.ports.app;
in
{
  services = {
    google-workspace-mcp = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        WORKSPACE_MCP_HOST = vmIp;
        WORKSPACE_MCP_PORT = port;
        PORT = port;
        USER_GOOGLE_EMAIL = buildJson.user_google_email;
        GOOGLE_SERVICE_ACCOUNT_KEY_PATH = "/run/secrets/GOOGLE_SERVICE_ACCOUNT_KEY";
      };
      # DIR-bind, not file-bind (2026-07-03): runc on oci-apps dies with
      # "mknod .../run/secrets/...: read-only file system" creating a FILE
      # mountpoint (tmpfs /run didn't help), while the fleet's standard
      # `.secrets.d:/run/secrets:ro` DIR-bind works on the same VM (rig).
      # The key file keeps its .secrets.d name; the env path points at it.
      volumes = [
        "./.secrets.d:/run/secrets:ro"
      ];
      healthcheck = {
        test = [
          "CMD"
          "curl"
          "-f"
          "http://${vmIp}:${port}/health"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };
}
