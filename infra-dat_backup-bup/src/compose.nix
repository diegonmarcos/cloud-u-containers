# compose.nix — docker-compose spec for bup (Type B wrap-upstream).
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service. Paths are relative to dist/
# (docker-compose project-directory at deploy time).
{ buildJson, container }:

let
  app       = buildJson.containers.app;
  sshPort   = toString buildJson.ports.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps
  # them into a GHCR image; at runtime we pull the published binaries
  # image. authorized_keys is bind-mounted read-only at /configs/authorized_keys
  # (NOT over /root/.ssh/authorized_keys: the entrypoint must chmod it, and
  # chmod on a read-only mount kills the container); init.sh copies it.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    bup = {
      image          = binariesImage;
      container_name = app.container_name;
      network_mode   = "host";
      entrypoint     = [ "sh" "/init.sh" ];
      environment = {
        TZ = buildJson.timezone or "UTC";
      };
      volumes = [
        "./configs/init.sh:/init.sh:ro"
        "./assets/authorized_keys:/configs/authorized_keys:ro"
        "bup_data:/backup/databases"
      ];
      # Override fleet restart policy — container-init owns lifecycle.
      restart = "no";
    };
  };

  volumes = {
    bup_data = {
      driver = "local";
      driver_opts = {
        type   = "none";
        o      = "bind";
        device = "/backup/databases";
      };
    };
  };
}
