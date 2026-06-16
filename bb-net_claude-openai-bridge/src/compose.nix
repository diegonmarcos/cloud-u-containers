# compose.nix — docker-compose for claude-openai-bridge.
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# WG-ONLY sidecar: host network, listener bound to the VM's WireGuard IP (10.0.0.6)
# — reachable only across the WG mesh, NEVER on the public NIC. No Caddy route, no
# published port. The only caller is the co-located octocode/cgc container (also
# host-network on oci-apps), which reaches it at <wg-ip>:PORT. octocode authenticates
# with a throwaway OPENAI_API_KEY (the bridge ignores it); the real credential (the
# Claude subscription OAuth token) lives only inside the bridge via env_file.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  svc = container.services or {};
  # WG IP from cloud-data (same pattern as cgc) → bind confines the listener to the
  # WG mesh. Nothing ever listens on the public IP for this service.
  wgIp = svc."claude-openai-bridge".ip or "10.0.0.6";
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    claude-openai-bridge = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        BRIDGE_PORT           = toString buildJson.ports.app;
        BRIDGE_BIND           = wgIp;
        BRIDGE_DEFAULT_MODEL  = "claude-sonnet-4-6";
        BRIDGE_MAX_CONCURRENCY = "3";
        BRIDGE_CALL_TIMEOUT_MS = "180000";
      };
      healthcheck = {
        test = [
          "CMD" "node" "-e"
          "fetch('http://${wgIp}:${toString buildJson.ports.app}/health').catch(()=>process.exit(1))"
        ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "20s";
      };
    };
  };
}
