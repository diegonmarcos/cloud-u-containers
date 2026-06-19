# compose.nix — docker-compose spec for caddy-public.
#
# Runs on oci-analytics and OWNS the public socket 0.0.0.0:443 via its own
# layer4 SNI mux (mail→maddy L4, pure-public→local :8443 L7, rest→gcp-proxy
# passthrough). The L7 server terminates TLS on :8443 (https_port set in the
# Caddyfile global block), serves the declared-public allowlist, and forwards
# WKD to gcp-proxy over wg-public (private_forward_upstream 10.1.0.2:443).
#
# Network: host (not bridge). Needs to bind :8443 directly on the VM and
# reach gcp-proxy over wg-public (10.1.0.x) + internal upstreams over wg0
# (10.0.0.x) without an intermediate Docker NAT hop. Mirrors every
# caddy / caddy-l4 deployment in the catalogue.
{ buildJson, container }:

{
  services = {
    caddy-public = {
      # Image declared in build.json (containers.app.image); compose reads it
      # directly so a single source of truth governs which binary image runs.
      image = buildJson.containers.app.image;
      container_name = buildJson.containers.app.container_name;
      network_mode = "host";
      env_file = [ ".secrets" ];          # CF_API_TOKEN for ACME DNS-01
      cap_add = [ "NET_BIND_SERVICE" ];
      read_only = false;
      volumes = [
        "./configs/Caddyfile:/etc/caddy/Caddyfile:ro"
        "./configs/error.html:/srv/error.html:ro"
        "caddy_public_logs:/var/log/caddy"
        "caddy_public_data:/data"
        "caddy_public_config:/config"
      ];
      # NO restart policy. Operator rule: failures stay down until manual
      # `build.sh ship` (see feedback_no_autorestart memory).
      restart = "no";
      deploy.resources = {
        limits       = { memory = "128M"; };
        reservations = { memory = "48M"; };
      };
    };
  };

  volumes = {
    caddy_public_data   = { driver = "local"; };
    caddy_public_config = { driver = "local"; };
    caddy_public_logs   = { driver = "local"; };
  };
}
