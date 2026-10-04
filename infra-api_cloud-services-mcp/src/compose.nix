# compose.nix — docker-compose spec for cloud-services-mcp (Type A own-code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."cloud-services-mcp".ip or "10.0.0.6";  # oci-apps WG IP
  port = toString buildJson.ports.app;

  # ── Resolve proxied MCP URLs from cloud-data ────────────────────
  # build.json declares child MCP names; each is looked up in `svc.<name>`
  # (from build-cloud-services-mcp.json) to get its WG IP + app port.
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
    cloud-services-mcp = {
      image          = binariesImage;
      container_name = app.container_name;
      # host network, not published ports. dockerd on this fleet runs with
      # iptables:false and userland-proxy:false (b_infra/_shared/vm-pilot/src/
      # modules/network/firewall.nix), so a published port has NO forwarding
      # mechanism: dockerd binds the socket and the container looks healthy --
      # it even logs the inbound initialize -- but the response never returns,
      # and outbound calls to other services on the WG IP fail outright.
      # Measured 2026-08-27, identical MCP initialize to three endpoints:
      #   mail-mcp (host network)  -> event: message {"result":...}
      #   bridge + ports           -> nothing
      # Confirmed by fixing cloud-drive-mcp the same way (024612772).
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        NODE_ENV      = "production";
        MCP_HTTP_PORT = port;
        # bindHost() reads MCP_HTTP_HOST. Defaults to 127.0.0.1 in source
        # (defensive, never expose by default). Under host network 0.0.0.0
        # would put the listener on every host interface, so pin it to the WG
        # IP — same convention as the sibling host-mode MCPs.
        MCP_HTTP_HOST = vmIp;
        NODE_OPTIONS  = "--max-old-space-size=1536";
        PROXIED_MCPS  = proxiedMcpsJson;
      };
      init = buildJson.runtime.init or false;
      # No memory ceiling — _shared/docker.nix made memLimit/cpuLimit inert
      # fleet-wide: deploy.resources.limits.memory becomes cgroup memory.max,
      # a LOCAL wall that force-reclaims from this container the instant it is
      # touched regardless of host free RAM. Pressure is the PSI watchdog's job.
      #
      # Read the limit CONDITIONALLY: build.json declares only mem_reservation,
      # and reading mem_limit unconditionally is what broke this service's build
      # outright ("attribute 'mem_limit' missing" at this line). Plain `if`
      # rather than lib.optionalAttrs because flake.nix does not pass `lib`.
      deploy.resources = {
        reservations = { memory = app.resources.mem_reservation; };
      } // (if app.resources ? mem_limit
            then { limits = { memory = app.resources.mem_limit; }; }
            else {});
      healthcheck = {
        test = [
          "CMD-SHELL"
          # Target vmIp, not localhost: with network_mode=host the app binds
          # MCP_HTTP_HOST (=vmIp) only, so localhost:${port} is never listening.
          "curl -so /dev/null -w '%{http_code}' http://${vmIp}:${port}${app.healthcheck} | grep -qE '^[2-4]' || exit 1"
        ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "15s";
      };
    };
  };
}
