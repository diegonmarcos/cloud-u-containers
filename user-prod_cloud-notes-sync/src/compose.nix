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
      ports = [ "${self.ip}:${toString buildJson.ports.app}:1234" ];
      environment = {
        PORT = "1234";
        SYNC_DB = "/data/sync.sqlite";
        # the same check the edge gate runs (infra-sec_introspect-proxy, mesh address of gcp-proxy)
        SYNC_FORWARD_AUTH_URL = "http://10.0.0.1:4182/auth";
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
