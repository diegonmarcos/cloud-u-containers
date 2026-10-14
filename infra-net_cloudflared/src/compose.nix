# compose.nix — pure attrset describing docker-compose.yml for cloudflared.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# cloudflared = connector for the remotely-managed Cloudflare Tunnel 'fleet-edge'
# (cloud-infra c_vps/ba-clo_cloudflare/src/zero-trust.tf). Outbound-only;
# TUNNEL_TOKEN comes from the sops-decrypted .secrets env file.
{ buildJson, container }:

let
  app = buildJson.containers.app;
in
{
  services = {
    cloudflared = {
      image          = app.image;
      container_name = app.container_name;
      command        = app.command;
      network_mode   = app.network_mode;
      read_only      = app.read_only;
      env_file       = [ ".secrets" ];
      environment = {
        TZ = buildJson.timezone or "Europe/Madrid";
      };
      cap_drop = [ "ALL" ];
      restart  = "unless-stopped";
      deploy = {
        resources =
             (if app.resources ? mem_limit       then { limits       = { memory = app.resources.mem_limit; };       } else {})
          // (if app.resources ? mem_reservation then { reservations = { memory = app.resources.mem_reservation; }; } else {});
      };
      logging = {
        driver = "json-file";
        options = {
          max-size = "1m";
          max-file = "3";
        };
      };
    };
  };
}
