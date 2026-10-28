# compose.nix - docker-compose for configs-sync (#1148). engine.nix serialises via lib.generators.toYAML.
# Scheduled publisher: derives the fleet JSONs and commits them to the data repo.
# GH_TOKEN (push to the data repo, read cloud-t-infra) comes from the service env file, never from here.
{ buildJson, container }:

let
  app = buildJson.containers.app;
in
{
  services = {
    configs-sync = {
      image          = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
      container_name = app.container_name;
      environment = {
        TZ            = buildJson.timezone;
        SCHEDULE_MIN  = "\${SCHEDULE_MIN:-15}";
        DATA_REPO     = "\${DATA_REPO:-diegonmarcos/cloudy_db_infra-ops-obsv_configs-sync}";
        CONTAINERS_REPO = "\${CONTAINERS_REPO:-diegonmarcos/cloudy-u-containers}";
        INFRA_REPO    = "\${INFRA_REPO:-diegonmarcos/cloudy-t-infra}";
        MODE          = "\${MODE:-full}";
      };
      env_file = [ ".env" ];
      volumes = [ "configs-sync-work:/work" ];
      healthcheck = {
        test     = [ "CMD" "test" "-f" "/work/last-ok" ];
        interval = "10m";
        timeout  = "5s";
        retries  = 3;
        start_period = "20m";
      };
      deploy.resources =
        if buildJson.resources ? mem_reservation then { reservations = { memory = buildJson.resources.mem_reservation; }; } else {};
    };
  };

  volumes = {
    configs-sync-work = { name = "configs-sync-work"; };
  };
}
