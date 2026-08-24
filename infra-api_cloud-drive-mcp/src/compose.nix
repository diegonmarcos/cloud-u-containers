# compose.nix — cloud-drive-mcp (Type A own-code, single container)
#
# Pure Nix; _shared/engine.nix serialises this to YAML. Nothing about the
# backends appears here: the `drive` routing table rides in build.json and
# reaches the container inside build-cloud-drive-mcp.json, which resolve.ts
# reads at runtime. Adding a backend is a JSON edit, never a compose change.
{ buildJson, container }:

let
  app  = buildJson.containers.app;
  svc  = container.services;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp          = svc."cloud-drive-mcp".ip;
  port          = toString buildJson.ports.app;
in
{
  services = {
    cloud-drive-mcp = {
      image          = binariesImage;
      container_name = app.container_name;
      ports          = [ "${vmIp}:${port}:${port}" ];
      env_file       = [ ".secrets" ];
      environment = {
        PORT = port;
      };
    };
  };
}
