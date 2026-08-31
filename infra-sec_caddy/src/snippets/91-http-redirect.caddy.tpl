  # Plain HTTP :80 → HTTPS. The global block sets `auto_https
  # disable_redirects`, so Caddy opens NO :80 listener on its own and every
  # http:// client got "failed to connect" while :443 answered 200 — the
  # Mattermost Android app probes http://chat.diegonmarcos.com before
  # upgrading, so it could never reach the server. This is the only site
  # here that is deliberately plain HTTP; the `http://` scheme keeps TLS
  # (and any cert issuance) off it.
  #
  # Mesh-only bind, NOT the publicBindLine used by the :8443 vhosts: the hub
  # is a private WireGuard node behind the single public edge, and the
  # collapse-to-443 plan the globals implement keeps its public surface at
  # one port. Redirecting on 10.0.0.1 serves mesh clients without opening a
  # new public socket. Separate port, so none of the byte-identical-bind
  # server-grouping rules that govern :8443 apply here.
  http:// {
    bind @WG_BIND_IP@
    redir https://{host}{uri} 308
  }
