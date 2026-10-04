  @CATCH_DOMAIN@ {
  @PUBLIC_BIND_LINE@
@SEC_NO_LIMIT@
    tls {
      dns cloudflare {env.CF_API_TOKEN}
      resolvers 1.1.1.1 8.8.8.8
      propagation_delay 30s
      propagation_timeout 5m
    }
    root * @CATCH_ROOT@
    rewrite * /@CATCH_FILE@
    # No matching vhost/route: serve the wormhole page but with a truthful 404.
    # A plain `file_server` returns 200 — a FALSE GREEN that made unrouted hosts
    # (e.g. webmail.diegonmarcos.com after its route was orphaned) look alive to
    # probes. Tag the response so probes detect the catch-all deterministically.
    header X-Edge-Fallback "1"
    header X-Edge-Route "catch-all"
    file_server {
      status 404
    }
  }
