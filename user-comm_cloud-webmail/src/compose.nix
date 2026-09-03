# compose.nix — pure attrset describing docker-compose.yml for cloud-webmail.
# engine.nix serialises it via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json (init/restart/logging/dns/security_opt/ulimits/
# pids) into it — so this file only carries the service-specific fields.
{ buildJson, container }:

let
  app = buildJson.containers.app;

  # Engine builds our own image and ships it to GHCR as
  # ghcr.io/diegonmarcos/<name>-binaries:latest (Type A). At runtime we pull
  # that image; compose_flags "--build" also rebuilds locally on deploy.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  port = toString buildJson.ports.app;
in
{
  services = {
    cloud-webmail = {
      image = binariesImage;
      container_name = app.container_name;
      # host network: binds 0.0.0.0:${port} on oci-mail, reachable via WG mesh
      # for Caddy's webmail.diegonmarcos.com reverse-proxy (auth two_factor).
      # VM INPUT policy is DROP except 10.0.0.0/24+lo, so :${port} stays
      # reachable only over the mesh. Mirrors how SnappyMail was exposed.
      network_mode = "host";
      environment = {
        # Runtime config (read at request time by /api/config — no rebuild
        # needed to change these). See src/code/amd64/webapp/.env.example.
        APP_NAME = "Cloud Webmail";
        JMAP_SERVER_URL = "https://jmap.diegonmarcos.com";
        NODE_ENV = "production";
        NEXT_TELEMETRY_DISABLED = "1";
        PORT = port;
        HOSTNAME = "0.0.0.0";
        LOG_FORMAT = "json";
        LOG_LEVEL = "info";
        # ponytail: OIDC/SSO left as follow-up — ship with Stalwart password
        # auth. To enable Authelia SSO, register a public PKCE client (see
        # build.json._doc._oidc_followup) and set:
        #   OAUTH_ENABLED=true
        #   OAUTH_CLIENT_ID=cloud-webmail
        #   OAUTH_ISSUER_URL=https://auth.diegonmarcos.com
        # SESSION_SECRET (remember-me) arrives via .secrets once a sops
        # secrets.yaml is added — engine auto-appends env_file:[.secrets].
      };
      healthcheck = {
        test = [ "CMD" "wget" "--no-verbose" "--tries=1" "--spider" "http://localhost:${port}/api/health" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "20s";
      };
      # Reservation only (a floor, not a ceiling) — same reasoning as the rest
      # of the fleet: cgroup memory.max caused scheduled reclaim thrashing.
      # Next.js needs materially more than SnappyMail's 16M.
      deploy.resources = {
        reservations = { memory = buildJson.resources.mem_reservation; };
      } // (if buildJson.resources ? mem_limit
            then { limits = { memory = buildJson.resources.mem_limit; }; }
            else {});
    };
  };
}
