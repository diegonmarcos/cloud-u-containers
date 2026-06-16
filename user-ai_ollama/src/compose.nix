# compose.nix — pure attrset describing docker-compose.yml for ollama.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps them
  # into a GHCR image; at runtime we pull the published binaries image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  wgIp         = svc.ollama.ip;
  apiPort      = toString buildJson.ports.app;
  timezone     = buildJson.timezone or "America/Chicago";
  keepAlive    = buildJson.ollama.keep_alive or "5m";
  kvCacheType  = buildJson.ollama.kv_cache_type or "q4_0";
in
{
  services = {
    ollama = {
      image = binariesImage;
      container_name = app.container_name;
      network_mode = "host";
      volumes = [ "ollama_data:/root/.ollama" ];
      environment = {
        TZ                   = timezone;
        OLLAMA_HOST          = "${wgIp}:${apiPort}";
        OLLAMA_KEEP_ALIVE    = keepAlive;
        OLLAMA_KV_CACHE_TYPE = kvCacheType;
        NVIDIA_VISIBLE_DEVICES = "all";
      };
      deploy.resources = {
        reservations.devices = [
          {
            driver = "nvidia";
            count = 1;
            capabilities = [ "gpu" ];
          }
        ];
      };
    };
  };
  volumes = {
    ollama_data = {};
  };
}
