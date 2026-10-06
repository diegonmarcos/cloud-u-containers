# compose.nix — docker-compose for jev-sidecar (#881).
# engine.nix serialises this via lib.generators.toYAML, merging compose-defaults.json.
#
# WG-ONLY (session-memory pattern): host network, the listener bound to the VM's WireGuard IP
# (10.0.0.6) — reachable by Dagu, journal-ntfy and the post-hoc scripts across the mesh, never the
# public NIC. No Caddy route, no published port.
#
# ONE SECRET: OPENROUTER_API_KEY, delivered through the .secrets env_file like every other AI key
# (src/secrets.yaml, sops). No key = every call answers {ok:false, reason:no_key} and the callers keep
# today's behaviour. The budget (daily USD cap, per-use hourly limits) is the one declared in
# _shared/jev-gate/jev-gate.json; its ledger, the answer cache and the journal live on the
# jev_sidecar_data volume, so a restart does not reset today's spend. The journal also goes to stdout,
# which the fleet's log-shipper sends to OpenObserve.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  svc = container.services or {};
  wgIp = svc."jev-sidecar".ip or "10.0.0.6";
  home = "/home/appuser";
in
{
  services = {
    jev-sidecar = {
      image = "ghcr.io/diegonmarcos/${buildJson.docker.image}-binaries:latest";
      container_name = app.container_name;
      network_mode = "host";
      environment = {
        HOME              = home;
        JEV_GATE_BIND     = wgIp;
        JEV_GATE_PORT     = toString buildJson.ports.app;
        JEV_GATE_CONFIG   = "/app/jev-gate/jev-gate.json";
      };
      volumes = [ "jev_sidecar_data:${home}" ];
      healthcheck = {
        test = [
          "CMD" "python3" "-c"
          "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://${wgIp}:${toString buildJson.ports.app}/health', timeout=3).status == 200 else 1)"
        ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "10s";
      };
      deploy.resources =
           { limits = { cpus = "0.25"; }; }
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };
  volumes = {
    jev_sidecar_data = { name = "jev-sidecar-data"; };
  };
}
