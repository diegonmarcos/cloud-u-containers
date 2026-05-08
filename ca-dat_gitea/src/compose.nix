# compose.nix — docker-compose spec for gitea (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  giteaConfig = buildJson.gitea;
  portHttp = buildJson.ports.app;
  portSsh  = buildJson.ssh_port;
  domain   = buildJson.domain;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    gitea = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        SSH_PORT                                     = toString portSsh;
        SSH_LISTEN_PORT                              = toString portSsh;
        GITEA__server__HTTP_PORT                     = toString portHttp;
        GITEA__server__SSH_PORT                      = toString portSsh;
        GITEA__server__SSH_LISTEN_PORT               = toString portSsh;
        GITEA__server__SSH_LISTEN_HOST               = buildJson.ssh_listen_host;
        GITEA__server__DISABLE_SSH                   = "false";
        GITEA__server__ROOT_URL                      = "https://${domain}";
        GITEA__server__SSH_DOMAIN                    = domain;
        GITEA__mirror__DEFAULT_INTERVAL              = giteaConfig.mirror_interval;
        GITEA__repository__ENABLE_PUSH_CREATE_USER   = "true";
        GITEA__repository__ENABLE_PUSH_CREATE_ORG    = "true";
      };
      volumes = [
        "gitea_data:/data"
        "/etc/timezone:/etc/timezone:ro"
        "/etc/localtime:/etc/localtime:ro"
      ];
      healthcheck = {
        test = [ "CMD" "curl" "-f" "http://localhost:${toString portHttp}/" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
      };
    };
  };
  volumes = {
    gitea_data = {};
  };
}
