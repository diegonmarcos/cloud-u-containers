{ buildJson, container }:

let
  svc           = container.services;
  app           = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  appPort = toString buildJson.ports.app;
  bindIp  = svc.openobserve.ip;
in
{
  services = {
    openobserve = {
      image          = binariesImage;
      container_name = app.container_name;
      network_mode   = "host";
      environment = {
        ZO_HTTP_PORT  = appPort;
        ZO_HTTP_ADDR  = bindIp;
        ZO_GRPC_PORT  = "5081";
        ZO_GRPC_ADDR  = bindIp;
        ZO_DATA_DIR   = "/data";
        ZO_LOCAL_MODE = "true";
        ZO_TELEMETRY  = "false";
        ZO_BASE_URI   = "";
      };
      volumes = [
        "openobserve_data:/data"
      ];
      # OpenObserve image is scratch-based (only /openobserve, no shell, no
      # wget/curl). Docker cannot exec any probe inside, so the in-container
      # healthcheck is disabled. Liveness comes from the process itself
      # (Docker exits the container if /openobserve crashes); external
      # /healthz monitoring is done by the cloud-infra MCP tools that hit
      # https://grafana.diegonmarcos.com/healthz from outside.
      healthcheck = {
        disable = true;
      };
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "128M"; };
      };
    };
  };

  volumes = {
    openobserve_data = {};
  };
}
