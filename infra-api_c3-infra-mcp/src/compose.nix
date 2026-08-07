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
  # WG IP from cloud-data — passed to bindHost() so the listener does NOT
  # default to 0.0.0.0 (which would expose every interface). host network
  # mode means binding to the WG IP keeps the service on the WG mesh only.
  vmIp = svc."c3-infra-mcp".ip or "10.0.0.6";
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
        # bindHost() reads MCP_HTTP_HOST. Defaults to 127.0.0.1 in source.
        # WG IP keeps the listener confined to the WG mesh on host network.
        MCP_HTTP_HOST = vmIp;
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
        "octocode_repos:/root/git"
      ];
      healthcheck = {
        test = [
          "CMD-SHELL"
          "curl -so /dev/null -w '%{http_code}' http://${vmIp}:${port}${healthPath} | grep -qE '^[2-4]' || exit 1"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "15s";
      };
    };
  };

  volumes = {
    octocode_repos = {
      name = "octocode_repos";
    };
  };
}
