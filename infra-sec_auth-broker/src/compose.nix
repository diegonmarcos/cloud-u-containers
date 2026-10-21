# compose.nix -- the auth broker: one device-flow broker container per provider (#1066).
# Providers, ports, prefixes, cookie and the allowlists all come from build.json auth_broker.
# Secrets arrive by compose interpolation from .secrets (deploy runs `--env-file .secrets`).
{ buildJson, container }:

let
  ab = buildJson.auth_broker;
  up = if ab.allowed_emails == [] || ab.allowed_github == []
       then throw "auth_broker allowlists are empty: refusing to render an open broker" else true;
  mk = p: let c = buildJson.containers.${p.id}; in {
    image = c.image;
    container_name = c.container_name;
    # Bind to the mesh address only (wg0-only policy); the hub and the edge dial it over the mesh.
    ports = [ "${buildJson.bind_host}:${toString p.port}:${toString p.port}" ];
    restart = "unless-stopped";
    environment = {
      BROKER_PROVIDER = p.id;
      PORT = toString p.port;
      BIND_HOST = "0.0.0.0";
      BROKER_CONFIG = "/app/build.json";
      # Shared by every instance so a session from one validates on all.
      AUTH_BROKER_COOKIE_SECRET = "\${AUTH_BROKER_COOKIE_SECRET}";
    } // (if p ? secret_prefix then {
      "${p.secret_prefix}_CLIENT_ID" = "\${${p.secret_prefix}_CLIENT_ID}";
      "${p.secret_prefix}_CLIENT_SECRET" = "\${${p.secret_prefix}_CLIENT_SECRET}";
    } else {});
    healthcheck = {
      test = [ "CMD" "python3" "-c"
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${toString p.port}${p.prefix}/health', timeout=4)" ];
      interval = "60s"; timeout = "10s"; retries = 3; start_period = "20s";
    };
    deploy.resources = {
      limits = { memory = c.resources.mem_limit; };
      reservations = { memory = c.resources.mem_reservation; };
    };
    logging = { driver = "json-file"; options = { max-size = "1m"; max-file = "3"; }; };
  };
in
builtins.seq up {
  services = builtins.listToAttrs (map (p: { name = "auth-broker-${p.id}"; value = mk p; }) ab.providers);
}
