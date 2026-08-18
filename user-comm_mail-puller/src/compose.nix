# compose.nix — pure attrset describing docker-compose.yml for mail-puller.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container }:

let
  app = buildJson.containers.app;
in
{
  services = {
    mail-puller = {
      image = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
      container_name = app.container_name;
      # host network: needs to reach co-located maddy :465 (implicit TLS;
      # Maddy dual-writes to Stalwart). Also simplifies outbound HTTPS to
      # Gmail/Outlook.
      network_mode = "host";
      # env_file marked optional: sops-encrypted secrets.yaml isn't populated
      # yet (OAuth client_id/secret/refresh_token). Container boots with empty
      # envs; sources without a matching env log a warning and back off; rest
      # keep working. Once secrets land, re-ship activates them.
      env_file = [ { path = ".secrets"; required = false; } ];
      volumes = [
        "mail_puller_state:/var/lib/mail-puller"
        "./configs/init.sh:/usr/local/bin/init.sh:ro"
        "./assets/sources.json:/etc/mail-puller/sources.json:ro"
      ];
      entrypoint = [ "sh" "/usr/local/bin/init.sh" ];
      deploy.resources = {
        limits       = { memory = app.resources.limits.memory;       cpus = "0.5"; };
        reservations = { memory = app.resources.reservations.memory; };
      };
    };
  };
  volumes = {
    mail_puller_state = {};
  };
}
