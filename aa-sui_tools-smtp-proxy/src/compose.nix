# compose.nix — docker-compose spec for smtp-proxy (Type A)
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    smtp-proxy = {
      image = binariesImage;
      container_name = app.container_name;
      restart = "no";
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        SMTP_HOST = "localhost";
        SMTP_PORT = "25";
        LISTEN_HOST = svc."smtp-proxy".ip;
        LISTEN_PORT = toString buildJson.ports.app;
        SMTP_SHADOW_HOST = "localhost";
        SMTP_SHADOW_PORT = "2025";
      };
    };
  };
}
