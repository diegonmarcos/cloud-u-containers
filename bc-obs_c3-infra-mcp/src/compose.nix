# compose.nix — docker-compose spec for c3-infra-mcp (Type A, own Node/TS code)
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  image = "ghcr.io/diegonmarcos/${buildJson.name}:latest";
  port = toString buildJson.ports.app;
  healthPath = buildJson.health.path;
  mattermostUrl = buildJson.env_config.mattermost_url;
  daguUrl = "http://${svc.dagu.ip}:${toString svc.dagu.ports.app}";
in
{
  services = {
    c3-infra-mcp = {
      image = image;
      container_name = app.container_name;
      network_mode = "host";
      init = buildJson.runtime.init or false;
      # Override fleet default pids=256 via deploy.resources (compose-defaults.json).
      # Using pids_limit conflicts with deploy.resources.limits.pids in compose v3.
      deploy.resources.limits.pids = buildJson.runtime.pids_limit or 256;
      env_file = [ ".secrets" ];
      environment = {
        NODE_ENV = "production";
        GIT_BASE = "/root/git";
        MM_URL = mattermostUrl;
        DAGU_API = daguUrl;
        MCP_HTTP_PORT = port;
        PATH = "/usr/local/nix-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        # entrypoint.sh sets HOME=/tmp/c3-home for SSH, which makes gcloud
        # look at /tmp/c3-home/.config/gcloud (empty) and fail with
        # "You do not currently have an active account selected".
        # CLOUDSDK_CONFIG pins gcloud to the mounted creds regardless of HOME.
        CLOUDSDK_CONFIG = "/root/.config/gcloud";
      };
      volumes = [
        "/opt/ssh-keys/${app.container_name}:/root/.ssh:ro"
        "/nix/store:/nix/store:ro"
        "/home/ubuntu/.nix-profile/bin:/usr/local/nix-bin:ro"
        "~/.config/gcloud:/root/.config/gcloud"
        "c3_git_repos:/root/git"
      ];
      healthcheck = {
        test = [
          "CMD-SHELL"
          "curl -so /dev/null -w '%{http_code}' http://localhost:${port}${healthPath} | grep -qE '^[2-4]' || exit 1"
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
