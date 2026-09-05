# compose.nix — cloud-vault-mcp (Type A own-code, single container)
#
# Pure Nix; _shared/engine.nix serialises this to YAML. Nothing about the
# personal-data layout appears here: the tools read the vault tree from disk
# under $VAULT_PATH and the fleet config from $CONFIG_PATH, both of which are
# plain paths inside the container. Adding a data source is a code/JSON edit,
# never a compose change.
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  svc  = container.services;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp          = svc."cloud-vault-mcp".ip;
  port          = toString buildJson.ports.app;
in
{
  services = {
    cloud-vault-mcp = {
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
      # The vault repo is the PRIVATE credential tree. It is mounted read-only
      # because every cloud_vault tool is read-only, and the container has no
      # other way to see it: the MCP reads $VAULT_PATH straight off disk, so
      # without this bind mount every tool reports an empty vault.
      volumes = [ "/home/ubuntu/git/vault:/vault:ro" ];
      environment = {
        PORT = port;
        # Bind the WG IP explicitly: under host network the listener would
        # otherwise sit on every host interface (it currently binds 0.0.0.0).
        # Same MCP_HTTP_HOST convention as the sibling host-mode MCPs.
        MCP_HTTP_HOST = vmIp;
        VAULT_PATH = "/vault";
        # build.include_cloud_data = "true" makes the ship engine copy the
        # consolidated fleet JSON into /app alongside the code.
        CONFIG_PATH = "/app/_cloud-data-consolidated.json";
      };
    };
  };
}
