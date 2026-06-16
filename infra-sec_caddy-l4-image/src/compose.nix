# compose.nix — docker-compose spec for caddy-l4-image (builder image)
#
# caddy-l4-image is an image-only service: it produces a custom Caddy
# binary (xcaddy-built with caddy-l4 + ratelimit + cloudflare-dns plugins)
# published to GHCR as ghcr.io/diegonmarcos/caddy-l4. The image is then
# consumed by bb-sec_caddy (fromImage in dockerfile_inline) — this service
# never runs as a container itself.
#
# Compose entry is a declarative record only; the ship engine treats this
# as an image build (step_docker), not a compose deployment.
{ buildJson, container }:

let
  app = container.container;
  builderImage = "ghcr.io/diegonmarcos/${buildJson.docker.image}:latest";
in
{
  services = {
    caddy-l4-image = {
      image          = builderImage;
      container_name = app.container_name;
      command        = [ "/usr/bin/caddy" "version" ];
      restart        = "no";
    };
  };
}
