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
    # Host network: the bridge gave the container no route to github.com / googleapis.com (device
    # code request timed out, 502). Same as cloud-infra-mcp. The listener binds the mesh address
    # only (wg0-only policy); the hub and the edge dial it over the mesh.
    network_mode = "host";
    restart = "unless-stopped";
    environment = {
      BROKER_PROVIDER = p.id;
      PORT = toString p.port;
      BIND_HOST = buildJson.bind_host;
      BROKER_CONFIG = "/app/build.json";
      # Shared by every instance so a session from one validates on all.
      AUTH_BROKER_COOKIE_SECRET = "\${AUTH_BROKER_COOKIE_SECRET}";
    } // (if p.flow == "email" then {
      # Mail delivery secrets (sops): Stalwart submission account, Resend API key. `:-` keeps compose quiet while absent.
      AUTH_BROKER_SMTP_USER = "\${AUTH_BROKER_SMTP_USER:-}";
      AUTH_BROKER_SMTP_PASSWORD = "\${AUTH_BROKER_SMTP_PASSWORD:-}";
      AUTH_BROKER_RESEND_API_KEY = "\${AUTH_BROKER_RESEND_API_KEY:-}";
    } else {}) // (if p ? secret_prefix then {
      "${p.secret_prefix}_CLIENT_ID" = "\${${p.secret_prefix}_CLIENT_ID}";
      "${p.secret_prefix}_CLIENT_SECRET" = "\${${p.secret_prefix}_CLIENT_SECRET}";
    } else {}) // (if (p.web or {}) ? secret_prefix then {
      # Web leg of a device-flow provider (GitHub OAuth App). `:-` keeps compose quiet while the
      # secret is not yet in sops; the broker then leaves the web leg off.
      "${p.web.secret_prefix}_CLIENT_SECRET" = "\${${p.web.secret_prefix}_CLIENT_SECRET:-}";
    } else {});
    healthcheck = {
      test = [ "CMD" "python3" "-c"
        "import urllib.request; urllib.request.urlopen('http://${buildJson.bind_host}:${toString p.port}${p.prefix}/health', timeout=4)" ];
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
