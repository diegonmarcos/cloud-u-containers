# compose.nix — pure attrset describing docker-compose.yml for kg-store (SurrealDB).
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  port = toString buildJson.ports.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps them
  # into a GHCR image; at runtime we pull the published binaries image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    surrealdb = {
      image          = binariesImage;
      container_name = app.container_name;
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      command =
        "start --log info --user root --pass \${SURREAL_ROOT_PASSWORD} "
        + "--bind 127.0.0.1:${port} file:/data/surreal.db";
      volumes = [ "${buildJson.data_path}:/data" ];
      healthcheck = {
        test         = [ "CMD" "/surreal" "is-ready" "--conn" "http://localhost:${port}" ];
        interval     = "15s";
        timeout      = "15s";
        retries      = 5;
        start_period = "30s";
      };
    };
  };
}
