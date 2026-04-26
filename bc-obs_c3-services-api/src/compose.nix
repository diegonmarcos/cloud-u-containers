# compose.nix — docker-compose spec for c3-services-api (Type A own-code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."c3-services-api".ip or "10.0.0.6";  # oci-apps WG IP
  port = toString buildJson.ports.app;
in
{
  services = {
    c3-services-api = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        HOST = vmIp;
        PORT = port;
        NODE_ENV = "production";
        # GIT_BASE — registry consumer reads
        # ${GIT_BASE}/cloud/2_configs/dist/cloud-data-c3-services-api.json
        # to populate SERVICE_DEFINITIONS at startup.
        GIT_BASE = "/root/git";
      };
      # Reuse the c3-infra-api git-repos volume on oci-apps. Same VM, same
      # cloud-data file source, same external named volume.
      volumes = [ "c3_git_repos:/root/git:ro" ];
      healthcheck = {
        test = [
          "CMD-SHELL"
          "curl -fsS http://${vmIp}:${port}/health >/dev/null 2>&1 || exit 1"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };
  volumes = {
    c3_git_repos = {
      external = true;
      name = "c3-mcp-api_c3-repos";
    };
  };
}
