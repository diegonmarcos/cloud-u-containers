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
    file_server
  }
