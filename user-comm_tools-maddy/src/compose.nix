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
        # Delivery-time Sieve-subset filter. Maddy forks the script per incoming
        # message via imap_filter.command (see maddy.conf.tpl). mail-rules.json
        # is the canonical single source of truth (also drives Stalwart's Sieve
        # via _shared/lib/mail-rules.nix; here we render the Maddy subset).
        "./assets/mail-rules.json:/data/mail-rules.json:ro"
        "./assets/mail-sieve-subset-delivery-time.sh:/usr/local/bin/mail-sieve-subset-delivery-time:ro"
        # Post-hoc maintenance script (operator-triggered via build.sh
        # post-hoc-* lifecycle hooks). SQL-direct on imapsql.db for 30k-scale
        # safety. Subcommands: integrity-check, integrity-fix, recover-headers,
        # apply-rules, dedupe, cleanup-mailboxes, all.
        "./assets/mail-sieve-subset-post-hoc.sh:/usr/local/bin/mail-sieve-subset-post-hoc:ro"
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
