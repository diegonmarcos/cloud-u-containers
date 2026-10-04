# compose.nix — docker-compose spec for cf-worker-http-to-wg-public-bridge (Type A)
#
# Bridge container on oci-analytics: receives CF-Worker POSTs and forwards to
# maddy/stalwart on oci-mail over the wg-public mesh.
#
# - LISTEN_HOST is the wg-public hub IP (10.1.0.1) on oci-analytics
# - SMTP_HOST is maddy on oci-mail's wg-public IP (10.1.0.3)
# - SMTP_SHADOW_HOST is stalwart on the same wg-public IP, port 2025
#
# When Phase 1 of the wg-public plan lands, container.services.<svc>.ip can
# replace these literals; until then we read from build.json bind_host /
# upstream peer hints to keep this declarative + traceable.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  listenHost = app.bind_host;
in
{
  services = {
    cf-worker-http-to-wg-public-bridge = {
      image = binariesImage;
      container_name = app.container_name;
      restart = "no";
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        SMTP_HOST = "10.1.0.3";
        SMTP_PORT = "25";
        LISTEN_HOST = listenHost;
        LISTEN_PORT = toString buildJson.ports.app;
        SMTP_SHADOW_HOST = "10.1.0.3";
        SMTP_SHADOW_PORT = "2025";
      };
    };
  };
}
