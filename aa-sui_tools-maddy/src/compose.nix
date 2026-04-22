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
        # DKIM keys: init.sh writes from DKIM_PRIVATE_KEY_B64 secret into the
        # maddy_data volume at /data/dkim. DO NOT bind-mount ./dkim here —
        # it would shadow the volume path with a read-only host dir and
        # crash init on first start. Source of truth is the sops secret.
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
