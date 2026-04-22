# compose.nix — pure attrset describing docker-compose.yml for backup-borg.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# Type B (wrap-upstream): alpine:3.19 is pulled, configs/ image mounts entrypoint.sh
# and authorized_keys into /configs at runtime. The entrypoint script installs
# borgbackup + openssh-server on first boot, then execs sshd.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    borg = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      entrypoint = [ "sh" "/configs/entrypoint.sh" ];
      volumes = [
        "borg_data:/backup/media"
        "./configs:/configs:ro"
      ];
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };
  };
  volumes = {
    borg_data = {
      driver = "local";
      driver_opts = {
        type = "none";
        o = "bind";
        device = "/backup/media";
      };
    };
  };
}
