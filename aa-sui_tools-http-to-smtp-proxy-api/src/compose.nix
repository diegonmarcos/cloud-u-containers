# compose.nix — docker-compose spec for http-to-smtp-proxy-api (Type A)
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    http-to-smtp-proxy-api = {
      image = binariesImage;
      container_name = app.container_name;
      restart = "no";
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        SMTP_HOST = "10.0.0.3";
        SMTP_PORT = "2025";
        LISTEN_HOST = svc."http-to-smtp-proxy-api".ip;
        LISTEN_PORT = toString buildJson.ports.app;
        SMTP_SHADOW_HOST = "10.0.0.3";
        SMTP_SHADOW_PORT = "2025";
      };
    };
  };
}
