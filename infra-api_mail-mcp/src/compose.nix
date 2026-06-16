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
  # Pin mail/jmap hostnames to the oci-mail WG IP via /etc/hosts so the
  # TCP connect lands on the correct backend over the mesh while TLS SNI
  # keeps using the public hostname (cert verification stays green).
  #
  # Background: Hickory DNS at 10.0.0.1:53 (the WG-mesh resolver this
  # container uses via compose `dns:`) resolves `mail.diegonmarcos.com`
  # via the catch-all wildcard → 10.0.0.1, which is the wrong VM in the
  # Phase-4 split-edge topology. We can't fix it in Hickory directly
  # because the REPORT container (also on the WG mesh) needs the same
  # hostname to keep resolving to the public Caddy edge for its HTTPS
  # probes — so we override per-container with `extra_hosts` instead.
  mailWgIp = "10.0.0.3";
in
{
  services = {
    mail-mcp = {
      image          = binariesImage;
      container_name = app.container_name;
      ports          = [ "${vmIp}:${port}:${port}" ];
      env_file       = [ ".secrets" ];
      extra_hosts    = [
        "${mh.maddy}:${mailWgIp}"
        "${mh.stalwart}:${mailWgIp}"
      ];
      environment = {
        PORT                = port;
        MAIL_HOST           = mailHost;
        MADDY_HOST          = mh.maddy;
        # SMTP connect-by-IP: nodemailer's dns.resolve() ignores the
        # extra_hosts /etc/hosts pin, so SMTP submission must target the WG IP
        # directly (TLS SNI stays on MADDY_HOST/STALWART_HOST for cert check).
        MADDY_SMTP_IP       = mailWgIp;
        STALWART_SMTP_IP    = mailWgIp;
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
