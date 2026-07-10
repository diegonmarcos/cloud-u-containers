  @SERVICE@ {
    # Bind must byte-match public routes: see 30-internal-route.caddy.tpl.
    # 2026-07-09.
@PUBLIC_BIND_LINE@
    tls internal {
      on_demand
    }
    reverse_proxy @UPSTREAM@ {
@EMPTY_GUARD@
    }
@HANDLE_ERRORS@
  }
