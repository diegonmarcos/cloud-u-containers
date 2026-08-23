# compose.nix — pure attrset describing docker-compose.yml for vaultwarden.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  svc = container.services;
  app = buildJson.containers.app;

  # Engine builds per-arch Dockerfiles into dist/code/<arch>/ and wraps them
  # into a GHCR image; at runtime we pull the published binaries image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    vaultwarden = {
      image = binariesImage;
      container_name = app.container_name;
      # Run the rendered init.sh (configs/init.sh) as the entrypoint: it asserts
      # the operator's verified_at in /data/db.sqlite3 then `exec /start.sh`
      # (vaultwarden/server's own CMD). Mirrors bb-sec_authelia. Failsafe — the
      # script always hands off to /start.sh, so the vault never fails to start.
      entrypoint = [ "sh" "/config/init.sh" ];
      network_mode = "host";
      read_only = true;
      tmpfs = [ "/tmp" ];
      # DAC_OVERRIDE: lets the init write verified_at into the data volume
      # regardless of file ownership (same rationale as bb-sec_authelia).
      cap_add = [ "DAC_OVERRIDE" ];
      env_file = [ ".secrets" ];
      environment = {
        TZ                  = buildJson.timezone;
        ROCKET_ADDRESS      = svc.vaultwarden.ip;           # bind to WG IP
        ROCKET_PORT         = toString buildJson.ports.app;
        DOMAIN              = "https://${buildJson.domain}";
        SIGNUPS_ALLOWED     = "true";
        INVITATIONS_ALLOWED = "true";
        SHOW_PASSWORD_HINT  = "false";
        WEBSOCKET_ENABLED   = "true";
        LOG_LEVEL           = "warn";
        # Advertise no client feature flags in /api/config. Vaultwarden's default
        # list announces pm-19148-innovation-archive, but this build does not emit
        # the archivedDate field on ciphers — so Bitwarden Android 2026.7.1 synced
        # all 1256 items (HTTP 200) and then filtered every one of them out of the
        # vault list. Empty = client falls back to pre-archive behaviour.
        EXPERIMENTAL_CLIENT_FEATURE_FLAGS = "";
        SMTP_HOST           = svc.maddy.ip;
        SMTP_PORT           = toString svc.maddy.ports.smtp;
        SMTP_FROM           = "noreply@${base_domain}";
        SMTP_USERNAME       = "noreply@${base_domain}";
        SMTP_SECURITY       = "force_tls";
        SMTP_PASSWORD       = "\${SMTP_PASSWORD}";
        ADMIN_TOKEN         = "\${ADMIN_TOKEN}";
      };
      volumes = [
        "vaultwarden_data:/data"
        "./configs:/config:ro"   # rendered init.sh (read-only)
      ];
      deploy.resources = {
        limits       = { memory = buildJson.resources.mem_limit;       cpus = "1.0"; };
        reservations = { memory = buildJson.resources.mem_reservation; };
      };
    };
  };
  volumes = {
    vaultwarden_data = {};
  };
}
