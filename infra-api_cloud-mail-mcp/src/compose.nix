# compose.nix — docker-compose spec for cloud-mail-mcp (Type A own-code)
#
# Pure-Nix attrset serialised to YAML by _shared/engine.nix. No heredocs.
# Single-container service: cloud-mail-mcp (IMAP/SMTP/Admin via Stalwart REST API).
{ buildJson, container }:

let
  svc   = container.services;
  app   = buildJson.containers.app;
  mh    = buildJson.mail_hosts;
  mp    = buildJson.mail_ports;

  binariesImage = "ghcr.io/diegonmarcos/${buildJson.name}-binaries:latest";
  vmIp          = svc."cloud-mail-mcp".ip;
  port          = toString buildJson.ports.app;
  # Cert is for mail.<base>; use domain for TLS SNI (not the raw WG IP).
  mailHost      = mh.maddy;
  stalwartJmap  = "https://${mh.stalwart}:${toString mp.stalwart_jmap_https}";

  # ── Resolve proxied MCP URLs from cloud-data (mirrors cloud-services-mcp) ──
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
    cloud-mail-mcp = {
      image          = binariesImage;
      container_name = app.container_name;
      # host, not bridge+published-ports. This fleet's daemon.json sets BOTH
      # "iptables": false AND "userland-proxy": false, so a published port has
      # NO forwarding mechanism at all: dockerd binds the socket (ss shows it
      # LISTENing, so it looks healthy) but nothing ever reaches the container
      # and every connection hangs until the client gives up.
      #
      # MEASURED on oci-apps 2026-08-25, same host, same moment:
      #   host-mode   google-personal-mcp :3106  -> HTTP 200 in 0.7ms
      #   bridge      cloud-mail-mcp      :3103  -> HTTP 000, timeout
      #   bridge      c3-services-mcp     :3101  -> HTTP 000, timeout
      #   direct to the container IP 172.21.0.2:3103 -> HTTP 200 in 5ms
      # i.e. the app was healthy the whole time; only the published-port path
      # was broken. Zero docker-proxy processes were running.
      #
      # b_infra/_shared/vm-pilot/src/modules/network/firewall.nix states this
      # as the fleet's design premise: "Docker runs with iptables:false — it
      # creates NO rules. All containers use network_mode: host — no DNAT, no
      # bridge isolation." This service simply wasn't following it.
      #
      # Host mode also fixes the ORIGINAL symptom (proxying to
      # google-personal-mcp failing with "fetch failed"): from a bridge netns,
      # 10.0.0.6:3106 is a HOST-bound address, so the packet hits the INPUT
      # chain — policy DROP, allowing only lo/wg0/wg-public/ESTABLISHED. The
      # docker subnet is whitelisted in FORWARD, not INPUT. Sharing the host
      # netns removes that hop entirely.
      network_mode   = "host";
      env_file       = [ ".secrets" ];
      extra_hosts    = [
        "${mh.maddy}:${mailWgIp}"
        "${mh.stalwart}:${mailWgIp}"
      ];
      environment = {
        PORT                = port;
        # Bind the WG mesh IP, not 0.0.0.0: under host networking the
        # listener would otherwise sit on every host interface. Same
        # MCP_HTTP_HOST convention the sibling host-mode MCPs use.
        MCP_HTTP_HOST       = vmIp;
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
