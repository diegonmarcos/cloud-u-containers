# compose.nix — pure attrset describing docker-compose.yml for sauron-central.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
#
# Two co-deployed containers (one service record in cloud-data):
#   - syslog-central : axosyslog upstream + config bind-mount
#   - siem-api       : python:3.11-slim upstream + app.py bind-mount
#
# Both use network_mode=host (legacy runtime choice) so no explicit port
# publish is needed. Config + app.py live in dist/configs/ after build and
# are shipped to the VM alongside compose/docker-compose.yml (see
# cloud-ship-container-engine.sh rsync step — DEPLOY_PATH is the dist/ root).
{ buildJson, container }:

let
  containers = buildJson.containers;
  syslog = containers.syslog;
  api    = containers.api;
in
{
  services = {
    syslog-central = {
      image          = syslog.upstream_image;
      container_name = syslog.container_name;
      network_mode   = "host";
      read_only      = false;
      volumes = [
        "./configs/syslog-ng-central.conf:/etc/syslog-ng/syslog-ng.conf:ro"
        "siem-data:/var/log/siem"
        "syslog-state:/var/lib/syslog-ng"
      ];
    };

    siem-api = {
      image          = api.upstream_image;
      container_name = api.container_name;
      network_mode   = "host";
      read_only      = false;
      command        = [ "python" "/app/app.py" ];
      environment = {
        DB_PATH = "/var/log/siem/alerts.db";
      };
      volumes = [
        "./configs/app.py:/app/app.py:ro"
        "siem-data:/var/log/siem"
      ];
    };
  };

  volumes = {
    siem-data    = {};
    syslog-state = {};
  };
}
