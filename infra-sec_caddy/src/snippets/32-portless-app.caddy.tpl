  @SERVICE@ {
    # Bind must byte-match public routes: see 30-internal-route.caddy.tpl.
    # 2026-07-09.
@PUBLIC_BIND_LINE@
    tls {
      on_demand
      issuer internal {
        ca mesh
      }
    }
    respond "@PLACEHOLDER_MSG@" 204
  }
