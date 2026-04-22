# compose.nix — docker-compose spec for ollama-hai (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  wgIp   = svc.${buildJson.name}.ip;
  apiPort = toString buildJson.ports.app;
in
{
  services = {
    ollama-hai = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      volumes = [
        "ollama_hai_data:/root/.ollama"
      ];
      environment = {
        TZ                       = buildJson.timezone;
        OLLAMA_KEEP_ALIVE        = buildJson.ollama.keep_alive;
        OLLAMA_HOST              = "${wgIp}:${apiPort}";
        OLLAMA_NUM_PARALLEL      = toString buildJson.ollama.num_parallel;
        OLLAMA_MAX_LOADED_MODELS = toString buildJson.ollama.max_loaded_models;
        OLLAMA_NUM_CTX           = toString buildJson.ollama.num_ctx;
      };
      deploy.resources = {
        limits = { memory = buildJson.resources.mem_limit; cpus = "2.0"; };
      };
      healthcheck = {
        test = [ "CMD" "ollama" "list" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "30s";
      };
    };
  };
  volumes = {
    ollama_hai_data = {};
  };
}
