  @SERVICE@ {
    # No explicit bind: see 30-internal-route.caddy.tpl — a narrow
    # `bind 10.0.0.1` put this site on its own unreachable Caddy server.
    # 2026-07-09.
    tls internal {
      on_demand
    }
    respond "DB catalog — container=@CONTAINER@ engine=@ENGINE@ port=@PORT@ upstream=@UPSTREAM@ path=@DB_PATH@ vm=@VM@" 200
  }
