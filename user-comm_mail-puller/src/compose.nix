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
      # No memory/cpu ceiling — see _shared/docker.nix, which made memLimit and
      # cpuLimit inert fleet-wide: deploy.resources.limits.memory becomes cgroup
      # memory.max, a LOCAL wall that force-reclaims from this container the
      # instant it is touched regardless of host free RAM. Pressure is
      # load-shedder's job now (PSI cpu/mem/io). Reservations stay: a floor is
      # protection, not a ceiling.
      #
      # Read the limit CONDITIONALLY so removing it from build.json degrades to
      # "no limit" instead of `attribute 'limits' missing`. Plain `if` rather
      # than lib.optionalAttrs because flake.nix does not pass `lib` here.
      deploy.resources = {
        reservations = { memory = app.resources.reservations.memory; };
      } // (if app.resources ? limits
            then { limits = { memory = app.resources.limits.memory; }; }
            else {});
    };
  };
  volumes = {
    mail_puller_state = {};
  };
}
