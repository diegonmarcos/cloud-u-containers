# compose.nix — docker-compose spec for mail-mcp (Type A own-code)
#
# Pure-Nix attrset serialised to YAML by _shared/engine.nix. No heredocs.
# Single-container service: mail-mcp (IMAP/SMTP/Admin via Stalwart REST API).
{ buildJson, container }:

let
  svc   = container.services;
  app   = buildJson.containers.app;
  mh    = buildJson.mail_hosts;
  mp    = buildJson.mail_ports;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp          = svc."mail-mcp".ip;
  port          = toString buildJson.ports.app;
  # Cert is for mail.<base>; use domain for TLS SNI (not the raw WG IP).
  mailHost      = mh.maddy;
  stalwartJmap  = "https://${mh.stalwart}:${toString mp.stalwart_jmap_https}";

  # ── Resolve proxied MCP URLs from cloud-data (mirrors c3-services-mcp) ──
  # build.json declares child MCP names; each is looked up in `svc.<name>` to
  # get its WG IP + app port. Bridge-mode container, so we use WG IPs.
  proxyCfg = buildJson.proxied_mcps or { children = []; retry = {
    initial_ms              = 10000;
    max_ms                  = 120000;
    max_retry_state_entries = 32;
  }; };
  resolveChild = child:
    let s = svc.${child.service}; in {
      inherit (child) name path;
      url = "http://${s.ip}:${toString s.ports.app}${child.path}";
    };
  proxiedMcps = {
    children = map resolveChild proxyCfg.children;
    retry    = proxyCfg.retry;
  };
  proxiedMcpsJson = builtins.toJSON proxiedMcps;
in
{
  services = {
    mail-mcp = {
      image          = binariesImage;
      container_name = app.container_name;
      ports          = [ "${vmIp}:${port}:${port}" ];
      env_file       = [ ".secrets" ];
      environment = {
        PORT                = port;
        MAIL_HOST           = mailHost;
        MADDY_HOST          = mh.maddy;
        MADDY_IMAP_PORT     = toString mp.maddy_imap;
        MADDY_SMTP_PORT     = toString mp.maddy_smtp;
        STALWART_HOST       = mh.stalwart;
        STALWART_IMAP_PORT  = toString mp.stalwart_imap;
        STALWART_SMTP_PORT  = toString mp.stalwart_smtp;
        STALWART_JMAP_URL   = stalwartJmap;
        PROXIED_MCPS        = proxiedMcpsJson;
      };
    };
  };
}
