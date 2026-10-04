# compose.nix — docker-compose spec for cloud-mattermost-mcp (Type A own-code)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp = svc."cloud-mattermost-mcp".ip or "10.0.0.6";
  port = toString buildJson.ports.app;
in
{
  services = {
    cloud-mattermost-mcp = {
      image = binariesImage;
      container_name = app.container_name;
      restart = "no";  # container-init handles startup
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
        MCP_HTTP_PORT = port;
        # Pin the listener to the WG IP under host network; this server
        # otherwise defaults to 0.0.0.0 (every host interface).
        MCP_HTTP_HOST = vmIp;
      };
    };
  };
}
