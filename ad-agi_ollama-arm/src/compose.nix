# compose.nix — docker-compose spec for ollama-arm (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  # ollama-arm VM (oci-apps-2) not yet in cloud-data; fall back to 0.0.0.0
  wg_ip = (svc."ollama-arm" or { ip = "0.0.0.0"; }).ip;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    ollama = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      volumes = [
        "ollama_data:/root/.ollama"
      ];
      environment = {
        TZ                       = "America/Chicago";
        OLLAMA_KEEP_ALIVE        = "10m";
        OLLAMA_HOST              = "${wg_ip}:${toString buildJson.ports.app}";
        OLLAMA_NUM_PARALLEL      = "2";
        OLLAMA_MAX_LOADED_MODELS = "1";
      };
      deploy.resources = {
        limits = { memory = "16G"; };
      };
    };
  };
  volumes = {
    ollama_data = {};
  };
}
