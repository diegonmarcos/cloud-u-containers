# compose.nix — pure attrset describing docker-compose.yml for maddy.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container, base_domain }:

let
  app = buildJson.containers.app;

  # Engine wraps the upstream maddy image into
  # ghcr.io/diegonmarcos/<name>-binaries:latest; at runtime we pull that image.
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    maddy = {
      image = binariesImage;
      container_name = app.container_name;
      # host network: maddy binds privileged SMTP/IMAP/submission ports
      # (25/143/465/587/993). VM INPUT policy is DROP except WG + lo, so
      # mail ports stay reachable only via the Caddy L4 proxy on gcp-proxy.
      network_mode = "host";
      entrypoint = [ "sh" "/etc/maddy/init.sh" ];
      env_file = [ ".secrets" ];
      volumes = [
        "maddy_data:/data"
        # Config + startup script (rendered by engine into dist/configs/)
        "./configs/maddy.conf.tpl:/etc/maddy/maddy.conf.tpl:ro"
        "./configs/init.sh:/etc/maddy/init.sh:ro"
        # Wildcard cert from Caddy, pushed out-of-band to the VM
        "./tls:/data/tls:ro"
        # DKIM keys (written by init.sh from DKIM_PRIVATE_KEY_B64 secret,
        # persisted via the maddy_data volume at /data/dkim). Mount here
        # kept for backward-compat with any pre-existing /opt/containers/maddy/dkim
        # directory; init.sh is the source of truth.
        "./dkim:/data/dkim:ro"
        # Delivery-time filter. Maddy forks mail-filter per incoming message via
        # imap_filter.command (see maddy.conf.tpl). mail-rules.json is the
        # declarative single source of truth for routing (Maddy-only schema:
        # pure MOVE, no Sieve/tags — Stalwart uses a different rules file).
        "./assets/mail-rules.json:/data/mail-rules.json:ro"
        "./assets/mail-filter.sh:/usr/local/bin/mail-filter:ro"
      ];
      deploy.resources = {
        limits       = { memory = app.resources.limits.memory;       cpus = "1.0"; };
        reservations = { memory = app.resources.reservations.memory; };
      };
    };
  };
  volumes = {
    maddy_data = {};
  };
}
