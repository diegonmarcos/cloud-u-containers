# compose.nix — docker-compose spec for sauron-forwarder (Type B, wrap upstream).
# engine.nix serialises this attrset via lib.generators.toYAML and deep-merges
# _shared/compose-defaults.json into every service.
#
# The container wraps debian:bookworm-slim. At runtime it apt-installs
# netcat-openbsd, then tails the external sauron-lite alerts log and forwards
# each new line to a central syslog endpoint over UDP via netcat.
{ buildJson, container }:

let
  ctr           = container.container;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";

  # Multi-line shell command kept as a single string.
  # In docker-compose, $$ escapes compose interpolation so the container shell
  # receives a literal $VAR. Nix indented strings (''...'') treat $$ as a
  # plain two-char sequence and ''${ as the escape for literal ${. Result:
  # docker-compose YAML keeps $$VAR / $${VAR} which the runtime sh expands.
  forwardScript = ''
    apt-get update && apt-get install -y --no-install-recommends netcat-openbsd && rm -rf /var/lib/apt/lists/*
    echo "Forwarding alerts to $''${CENTRAL_HOST}:$''${CENTRAL_PORT}"
    tail -F /var/log/sauron/alerts.jsonl 2>/dev/null | while read line; do
      echo "$$line" | nc -w1 $''${CENTRAL_HOST} $''${CENTRAL_PORT} 2>/dev/null || true
    done
  '';
in
{
  services = {
    sauron-forwarder = {
      image          = binariesImage;
      container_name = ctr.container_name;
      network_mode   = "host";
      environment = {
        CENTRAL_HOST = "\${CENTRAL_HOST}";
        CENTRAL_PORT = "\${CENTRAL_PORT:-5514}";
      };
      volumes = [
        "sauron-data:/var/log/sauron:ro"
      ];
      entrypoint = [ "/bin/sh" "-c" ];
      command    = [ forwardScript ];
      deploy.resources = {
        limits       = { memory = "64M"; cpus = "1.0"; };
        reservations = { memory = "16M"; };
      };
    };
  };

  # External volume owned by the sauron-lite compose project on the same VM.
  volumes = {
    sauron-data = {
      name     = "sauron-lite_sauron-data";
      external = true;
    };
  };
}
