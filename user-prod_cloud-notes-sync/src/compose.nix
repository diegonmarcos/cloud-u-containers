# compose.nix — Cloud Notes sync server. Hocuspocus + SQLite in /data (named volume). It refuses to
# start without a verifier, so the introspect-proxy URL is part of the declaration, not a default.
{ buildJson, container, base_domain }:

let
  svc  = container.services;
  self = svc."cloud-notes-sync";
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    cloud-notes-sync = {
      image = binariesImage;
      container_name = buildJson.containers.app.container_name;
      # Host network, bound to the WG IP (the oci-apps convention, like continuwuity/gitea). A bridge
      # network cannot reach the introspect-proxy on gcp-proxy: compose puts it in 192.168.x, outside the
      # 172.16.0.0/12 the VM masquerades, so its packets leave via wg0 with an unroutable source and the
      # verifier fails closed (every authenticated call answered 401).
      network_mode = "host";
      environment = {
        HOST = self.ip;
        PORT = toString buildJson.ports.app;
        SYNC_DB = "/data/sync.sqlite";
        # the same check the edge gate runs (infra-sec_introspect-proxy, mesh address of gcp-proxy)
        SYNC_FORWARD_AUTH_URL = "http://10.0.0.1:4182/auth";
      };
      # The image's own HEALTHCHECK probes 127.0.0.1:$PORT. On the host network the server binds the
      # WG IP only (never 0.0.0.0: wg-only policy), so that probe finds no listener and the container
      # reads "unhealthy" while serving fine. Probe the address it actually binds.
      healthcheck = {
        test = [ "CMD" "node" "-e"
          "fetch('http://${self.ip}:${toString buildJson.ports.app}/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 3;
        start_period = "20s";
      };
      volumes = [ "cloud_notes_sync_data:/data" ];
      deploy.resources =
           { limits = { cpus = "0.5"; } // (if buildJson.resources ? mem_limit then { memory = buildJson.resources.mem_limit; } else {}); }
        // (if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {});
    };
  };
  volumes = {
    cloud_notes_sync_data = {};
  };
}
