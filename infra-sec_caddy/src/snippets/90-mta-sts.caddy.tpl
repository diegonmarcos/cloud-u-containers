  @MTA_DOMAIN@ {
  @PUBLIC_BIND_LINE@
@SEC_NO_LIMIT@
    @EDGE_GATE@
    tls {
      dns cloudflare {env.CF_API_TOKEN}
      resolvers 1.1.1.1 8.8.8.8
      propagation_delay 30s
      propagation_timeout 5m
    }
    handle @MTA_POLICY_PATH@ {
      header Content-Type "text/plain"
      respond "version: STSv1
mode: @MTA_MODE@
@MTA_MX_LINES@
max_age: @MTA_MAX_AGE@
" 200
    }
    # Wrapped in handle: the global options carry `order respond before handle`, so a
    # bare site-level `respond 404` ran BEFORE the policy handle above and 404ed it.
    handle {
      respond 404
    }
  }
