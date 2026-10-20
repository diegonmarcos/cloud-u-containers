# compose.nix -- the auth broker: one oauth2-proxy per provider (#1066).
# Providers, ports, prefixes, cookie and the allowlist all come from build.json auth_broker.
# Secrets arrive by compose interpolation from .secrets (deploy runs `--env-file .secrets`).
{ buildJson, container }:

let
  ab = buildJson.auth_broker;
  up = if ab.allowed_emails == [] then throw "auth_broker.allowed_emails is empty: refusing to render an open broker" else true;
  secretKey = p: k: "\${" + p.secret_prefix + "_" + k + "}";
  mk = p: let c = buildJson.containers.${p.id}; in {
    image = c.image;
    container_name = c.container_name;
    # Bind to the mesh address only (wg0-only policy); the hub and the edge dial it over the mesh.
    ports = [ "${buildJson.bind_host}:${toString p.port}:4180" ];
    volumes = c.volumes;
    restart = "unless-stopped";
    environment = {
      OAUTH2_PROXY_PROVIDER = p.provider;
      OAUTH2_PROXY_CLIENT_ID = secretKey p "CLIENT_ID";
      OAUTH2_PROXY_CLIENT_SECRET = secretKey p "CLIENT_SECRET";
      OAUTH2_PROXY_COOKIE_SECRET = "\${AUTH_BROKER_COOKIE_SECRET}";
      OAUTH2_PROXY_HTTP_ADDRESS = "0.0.0.0:4180";
      OAUTH2_PROXY_PROXY_PREFIX = p.prefix;
      OAUTH2_PROXY_SCOPE = p.scope;
      # Identity: ONLY the allowlist. No email-domain rule exists (see build.json _doc).
      OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE = "/etc/oauth2-proxy/allowed-emails.txt";
      OAUTH2_PROXY_COOKIE_NAME = ab.cookie_name;
      OAUTH2_PROXY_COOKIE_DOMAINS = ab.cookie_domain;
      OAUTH2_PROXY_WHITELIST_DOMAINS = ab.cookie_domain;
      OAUTH2_PROXY_COOKIE_EXPIRE = ab.cookie_expire;
      OAUTH2_PROXY_COOKIE_REFRESH = "0";
      OAUTH2_PROXY_COOKIE_SECURE = "true";
      OAUTH2_PROXY_COOKIE_SAMESITE = "lax";
      OAUTH2_PROXY_REVERSE_PROXY = "true";
      OAUTH2_PROXY_UPSTREAMS = "static://202";
      OAUTH2_PROXY_SET_XAUTHREQUEST = "true";
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON = "true";
      OAUTH2_PROXY_SILENCE_PING_LOGGING = "true";
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
