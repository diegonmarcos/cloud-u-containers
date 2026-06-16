# compose.nix — docker-compose spec for c3-services-mcp (Type A own-code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."c3-services-mcp".ip or "10.0.0.6";  # oci-apps WG IP
  port = toString buildJson.ports.app;

  # ── Resolve proxied MCP URLs from cloud-data ────────────────────
  # build.json declares child MCP names; each is looked up in `svc.<name>`
  # (from build-c3-services-mcp.json) to get its WG IP + app port.
  # This container runs in bridge mode — 127.0.0.1 inside the container is
  # NOT the host, so we MUST use the WG IP for every child.
  proxyCfg = buildJson.proxied_mcps;
  resolveChild = child:
    let s = svc.${child.service}; in {
      inherit (child) name path;
      url = "http://${s.ip}:${toString s.ports.app}${child.path}";
    };
  proxiedMcps = {
    infra = map resolveChild proxyCfg.infra;
    user  = map resolveChild proxyCfg.user;
    retry = {
      initial_ms              = proxyCfg.retry.initial_ms;
      max_ms                  = proxyCfg.retry.max_ms;
      max_retry_state_entries = proxyCfg.retry.max_retry_state_entries;
    };
  };
  proxiedMcpsJson = builtins.toJSON proxiedMcps;

in
{
  services = {
    c3-services-mcp = {
      image          = binariesImage;
      container_name = app.container_name;
      # Bridge mode — port mapping binds to WG IP only (NOT host network).
      ports = [ "${vmIp}:${port}:${port}" ];
      env_file = [ ".secrets" ];
      environment = {
        NODE_ENV      = "production";
        MCP_HTTP_PORT = port;
        # bindHost() reads MCP_HTTP_HOST. Defaults to 127.0.0.1 in source
        # (defensive, never expose by default). Bridge-mode containers must
        # accept on the container's own private net namespace, so 0.0.0.0
        # is scoped to the container — docker maps from WG IP via the
        # `ports = [ "${vmIp}:${port}:${port}" ]` rule above.
        MCP_HTTP_HOST = "0.0.0.0";
        NODE_OPTIONS  = "--max-old-space-size=1536";
        PROXIED_MCPS  = proxiedMcpsJson;
      };
      init = buildJson.runtime.init or false;
      deploy.resources = {
        limits       = { memory = app.resources.mem_limit; };
        reservations = { memory = app.resources.mem_reservation; };
      };
      healthcheck = {
        test = [
          "CMD-SHELL"
          "curl -so /dev/null -w '%{http_code}' http://localhost:${port}${app.healthcheck} | grep -qE '^[2-4]' || exit 1"
        ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "15s";
      };
    };
  };
}
