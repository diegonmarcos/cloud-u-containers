# compose.nix — cloud-drive-mcp (Type A own-code, single container)
#
# Pure Nix; _shared/engine.nix serialises this to YAML. Nothing about the
# backends appears here: the `drive` routing table rides in build.json and
# reaches the container inside build-cloud-drive-mcp.json, which resolve.ts
# reads at runtime. Adding a backend is a JSON edit, never a compose change.
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  svc  = container.services;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp          = svc."cloud-drive-mcp".ip;
  port          = toString buildJson.ports.app;
in
{
  services = {
    cloud-drive-mcp = {
      image          = binariesImage;
      container_name = app.container_name;
      # host network, not published ports. The fleet runs dockerd with
      # iptables:false and userland-proxy:false (b_infra/_shared/vm-pilot/src/
      # modules/network/firewall.nix), so a published port has NO forwarding
      # mechanism: dockerd binds the socket -- the container even looks healthy
      # and logs the inbound initialize -- but the response never gets back.
      # Measured 2026-08-27, identical request to three endpoints:
      #   mail-mcp (host)         -> event: message {"result":...}
      #   cloud-drive-mcp (ports) -> nothing
      #   mattermost-mcp (ports)  -> nothing
      # Same conclusion cloud-mail-mcp already documents from 2026-08-25.
      network_mode   = "host";
      # Optional: this service has no secrets.yaml, so ship logs "No secrets.yaml
      # -- skipping" and never writes .secrets. A required env_file makes compose
      # abort before it even pulls, which is why the deploy failure surfaced as
      # "binaries:latest neither pullable nor cached" -- the pull never ran.
      # Same idiom as user-comm_mail-puller.
      env_file       = [ { path = ".secrets"; required = false; } ];
      environment = {
        PORT = port;
        # Bind the WG IP explicitly: under host network the listener would
        # otherwise sit on every host interface (it currently binds 0.0.0.0).
        # Same MCP_HTTP_HOST convention as the sibling host-mode MCPs.
        MCP_HTTP_HOST = vmIp;
      };
    };
  };
}
