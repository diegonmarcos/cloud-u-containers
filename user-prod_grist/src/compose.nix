# compose.nix — pure attrset describing docker-compose.yml for grist.
# engine.nix serialises it via lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, container }:

let
  svc = container.services;
  app = buildJson.containers.app;
  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
in
{
  services = {
    grist = {
      image = binariesImage;
      container_name = app.container_name;
      environment = {
        PORT               = toString buildJson.ports.app;
        GRIST_SESSION_SECRET = "changeme-secret-key";
        GRIST_SINGLE_ORG     = "docs";
        GRIST_DEFAULT_EMAIL  = "\${GRIST_ADMIN_EMAIL:-${buildJson.grist_admin_email}}";
        APP_HOME_URL         = "https://${buildJson.domain}";
        GRIST_SANDBOX_FLAVOR = "unsandboxed";
        GRIST_LOG_LEVEL      = "info";
        # SSO (#1147): Authelia OIDC. Inert while GRIST_OIDC_CLIENT_SECRET is unset (the
        # issuer and client id interpolate to empty, grist keeps its own login).
        GRIST_OIDC_IDP_ISSUER        = "\${GRIST_OIDC_CLIENT_SECRET:+https://sso.diegonmarcos.com}";
        GRIST_OIDC_IDP_CLIENT_ID     = "\${GRIST_OIDC_CLIENT_SECRET:+grist}";
        GRIST_OIDC_IDP_CLIENT_SECRET = "\${GRIST_OIDC_CLIENT_SECRET:-}";
        GRIST_OIDC_IDP_SCOPES        = "openid profile email";
        # Authelia publishes no end_session_endpoint; without this grist exits 1 at start.
        GRIST_OIDC_IDP_SKIP_END_SESSION_ENDPOINT = "true";
        # docs.getgrist.com/install/oidc: SP host is the Grist base URL; callback is <host>/oauth2/callback.
        GRIST_OIDC_SP_HOST           = "https://${buildJson.domain}";
      };
      ports = [
        # Tier-3 wg-only bind: data-driven IP from container.services.<self>.ip
        # (cloud-data-config-derive emits svc.<name>.ip per VM WG address).
        "${svc.grist.ip}:${toString buildJson.ports.app}:${toString buildJson.ports.app}"
      ];
      volumes = [
        "grist_data:/persist"
      ];
      healthcheck = {
        test = [ "CMD" "curl" "-f" "http://localhost:${toString buildJson.ports.app}/" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
    };
  };
  volumes = {
    grist_data = {};
  };
}
