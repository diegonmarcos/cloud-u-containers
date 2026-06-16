# compose.nix — docker-compose spec for caddy-l4-public.
#
# Runs on oci-analytics, owns 0.0.0.0:443. Pre-built image
# ghcr.io/diegonmarcos/caddy-l4 (xcaddy'd with caddy-l4 + ratelimit +
# cloudflare-dns plugins by bb-sec_caddy-l4-image). This service does NOT
# need its own build — it just runs the published image with our Caddyfile
# mounted in.
#
# Network: host (not bridge). The container needs to bind 0.0.0.0:443
# directly on the VM's public NIC so external traffic to oci-analytics
# arrives without an intermediate Docker NAT hop. Per the established
# pattern of every caddy / caddy-l4 deployment in the catalogue.
{ buildJson, container }:

let
  app = buildJson.containers.app;
  image = "ghcr.io/diegonmarcos/${buildJson.docker.image}:${buildJson.docker.image_tag or "latest"}";
in
{
  services = {
    caddy-l4-public = {
      image          = image;
      container_name = app.container_name;
      network_mode   = "host";
      # Mount the Caddyfile into the standard Caddy config path.
      # `:ro` because the container should never write to its own config.
      volumes = [
        "./configs/Caddyfile:/etc/caddy/Caddyfile:ro"
      ];
      command = [ "caddy" "run" "--config" "/etc/caddy/Caddyfile" "--adapter" "caddyfile" ];
      # NO restart policy. Operator rule: failures stay down until manual
      # `build.sh ship` (see feedback_no_autorestart memory).
      restart = "no";
      logging = {
        driver = "json-file";
        options = {
          max-size = "10m";
          max-file = "3";
        };
      };
    };
  };
}
