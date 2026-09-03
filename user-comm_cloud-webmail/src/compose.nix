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
        # needed to change these). See src/code/arm64/webapp/.env.example.
        APP_NAME = "Cloud Webmail";
        APP_SHORT_NAME = "Webmail";
        APP_DESCRIPTION = "Cloud Webmail — Stalwart-native JMAP mail, calendar and contacts.";
        JMAP_SERVER_URL = "https://jmap.diegonmarcos.com";
        # Multi-account / multi-server: exposes a "JMAP Server" field on the
        # login form so users can connect additional JMAP servers beyond the
        # default JMAP_SERVER_URL above. (.env.example: "Allow users to specify
        # a custom JMAP server URL on the login form.")
        ALLOW_CUSTOM_JMAP_ENDPOINT = "true";
        # Stalwart-specific features: password change + Sieve filters, etc.
        # (.env.example: "Enable Stalwart-specific features (password change,
        # sieve filters, etc.). Set to 'false' to disable…") — value is a bool.
        STALWART_FEATURES = "true";
        # Encrypted server-side settings persistence — needs SESSION_SECRET.
        SETTINGS_SYNC_ENABLED = "true";
        # SESSION_SECRET encrypts stored credentials / "remember me" / settings
        # sync. Wired as a SECRET via the engine's sops mechanism: when
        # src/secrets.yaml (sops/age) defines SESSION_SECRET, the ship engine
        # decrypts it to dist/.secrets.d/SESSION_SECRET and mounts .secrets.d at
        # /run/secrets (see _shared/engine.nix). Bulwark reads the file path
        # from SESSION_SECRET_FILE. The parent must populate the sops key
        # SESSION_SECRET (openssl rand -base64 32) in src/secrets.yaml.
        SESSION_SECRET_FILE = "/run/secrets/SESSION_SECRET";
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
