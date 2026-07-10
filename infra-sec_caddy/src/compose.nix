# compose.nix — docker-compose spec for caddy
# introspect-proxy lives in its own service folder (bb-sec_introspect-proxy)
# and runs as its own compose project; Caddy reaches it over host network
# at 127.0.0.1:4182 (or 10.0.0.1:4182 for WG-side forward_auth).
{ buildJson, container }:

{
  services = {
    caddy = {
      # Image declared in build.json (containers.app.image); compose reads it
      # directly so a single source of truth governs which binary image runs.
      image = buildJson.containers.app.image;
      container_name = buildJson.containers.app.container_name;
      # REQUIRED: the caddy-l4 image's default CMD is ["/bin/sh"] (it ships a bare
      # shell, NOT `caddy run`). Without an explicit command the container runs sh,
      # exits instantly, and :443 goes dark with empty logs — the gcp-proxy outage
      # of 2026-06-19. Every caddy-l4 consumer MUST declare this command.
      command = [ "caddy" "run" "--config" "/etc/caddy/Caddyfile" "--adapter" "caddyfile" ];
      network_mode = "host";
      env_file = [ ".secrets" ];
      cap_add = [ "NET_BIND_SERVICE" ];
      read_only = false;
      volumes = [
        # Per-key secret files from the sops pipeline (.secrets.d/<KEY>, mode
        # 0600) — carries the mesh-CA PEM key+cert that the pki global block
        # (00-globals.caddy.tpl) reads at /run/secrets/MESH_CA_{KEY,CERT}.
        # Multi-line PEM can't ride the .secrets env_file, files can.
        "./.secrets.d:/run/secrets:ro"
        "./configs/Caddyfile:/etc/caddy/Caddyfile:ro"
        "./configs/error.html:/srv/error.html:ro"
        "./configs/dashboard.html:/srv/dashboard.html:ro"
        "./configs/ntfy-setup.html:/srv/ntfy-setup.html:ro"
        "./configs/mail:/srv/mail:ro"
        "./configs/wkd:/srv/wkd:ro"
        "caddy_logs:/var/log/caddy"
        "caddy_data:/data"
        "caddy_config:/config"
      ];
      deploy.resources = {
        limits       = { memory = "128M"; };
        reservations = { memory = "48M"; };
      };
    };
  };

  volumes = {
    caddy_data   = { driver = "local"; };
    caddy_config = { driver = "local"; };
    caddy_logs   = { driver = "local"; };
  };
}
