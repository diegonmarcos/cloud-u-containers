# compose.nix — pure attrset describing docker-compose.yml for continuwuity.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  svc  = container.services;
  self = svc."matrix-continuwuity";

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ (FROM upstream_image)
  # and wraps them into a GHCR image; at runtime we pull the published image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # server_name is the Matrix identity domain (user IDs = @user:diegonmarcos.com).
  # Federation + clients are delegated to matrix.diegonmarcos.com over :443 via
  # the .well-known JSON below — so no public 8448 is opened.
  serverName = base_domain;
  delegated  = buildJson.domain;
in
{
  services = {
    continuwuity = {
      image = binariesImage;
      container_name = buildJson.containers.app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];
      environment = {
        TZ                              = buildJson.timezone;
        CONTINUWUITY_SERVER_NAME        = serverName;
        CONTINUWUITY_ADDRESS            = self.ip;                       # bind to WG IP
        CONTINUWUITY_PORT               = toString buildJson.ports.app;
        CONTINUWUITY_DATABASE_PATH      = "/var/lib/continuwuity";
        CONTINUWUITY_DATABASE_BACKEND   = "rocksdb";
        CONTINUWUITY_ALLOW_FEDERATION   = "true";
        CONTINUWUITY_ALLOW_REGISTRATION = "true";
        CONTINUWUITY_REGISTRATION_TOKEN = "\${CONTINUWUITY_REGISTRATION_TOKEN}";
        CONTINUWUITY_WELL_KNOWN         = "{ client=https://${delegated}, server=${delegated}:443 }";
        CONTINUWUITY_ALLOW_PUBLIC_ROOM_DIRECTORY_OVER_FEDERATION = "false";
        CONTINUWUITY_TRUSTED_SERVERS    = "[\"matrix.org\"]";
      };
      volumes = [ "continuwuity_data:/var/lib/continuwuity" ];
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "2.0"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };
  volumes = {
    continuwuity_data = {};
  };
}
