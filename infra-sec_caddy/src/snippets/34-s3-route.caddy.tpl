  @SERVICE@ {
    # No explicit bind: see 30-internal-route.caddy.tpl — a narrow
    # `bind 10.0.0.1` put this site on its own unreachable Caddy server.
    # 2026-07-09.
    tls internal
    rewrite * /@BUCKET@{uri}
    reverse_proxy @S3_ENDPOINT@ {
      header_up Host @S3_HOST@
    }
  }
