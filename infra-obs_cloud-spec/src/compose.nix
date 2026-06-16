# compose.nix — docker-compose spec for cloud-spec (Type B, wrap busybox)
#
# Serves a static mdbook-built documentation site from dist/assets/site
# via busybox httpd on host network. engine.nix serialises this attrset
# via lib.generators.toYAML and deep-merges _shared/compose-defaults.json.
{ buildJson, container }:

let
  app = buildJson.containers.app;

  # Engine emits dist/code/<arch>/Dockerfile that wraps buildJson.containers.app.image
  # (busybox:latest) and ships it to GHCR as <name>-binaries:latest.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  port = toString app.port;

  # Static-serve command — %PORT% substituted with the declared port
  runtimeCmd =
    builtins.replaceStrings [ "%PORT%" ] [ port ] buildJson.runtime.command;
in
{
  services = {
    cloud-spec = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      command = runtimeCmd;
      # mdbook site built in flake.nix, copied into dist/assets/site/
      volumes = [
        "./assets/site:/srv:ro"
      ];
      deploy.resources = {
        limits       = { memory = "512M"; cpus = "1.0"; };
        reservations = { memory = "64M"; };
      };
    };
  };
}
