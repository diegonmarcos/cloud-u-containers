# compose.nix — docker-compose spec for ollama-arm (Type B wrap-upstream)
# engine.nix serialises this attrset via lib.generators.toYAML and merges
# compose-defaults.json into every service.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  # WG-bind from cloud-data — engine-resolved (resolveBindHost in
  # 2_configs/src/engines/cloud-data-config-derive.ts). For ollama-arm the
  # deploy-target VM (oci-apps-2) must exist in cloud-data; otherwise the
  # engine returns the "vm.wg_ip" sentinel — fail loud (no silent 0.0.0.0).
  wg_ip =
    if container.bind_host == null || container.bind_host == "vm.wg_ip"
    then throw ''
      ollama-arm: container.bind_host is unresolved — VM '${container.vm}' is
      missing a WG mesh entry in cloud-data. Add the VM to
      I_cloud-data/cloud-data-* + re-run 2_configs/build.sh all to populate
      bind_host; refusing to bind to 0.0.0.0 on a public surface.
    ''
    else container.bind_host;
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
