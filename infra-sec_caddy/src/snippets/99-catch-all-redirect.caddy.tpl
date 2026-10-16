  # ════════════════════════════════════════════════════════════
  # CATCH-ALL (landing redirect): unknown subdomains 302 to the landing hub
  # instead of the 404 error page (url-scheme.md). Any host a more specific
  # site block does not claim lands here; the wildcard cert covers the name.
  # ════════════════════════════════════════════════════════════
  @CATCH_DOMAIN@ {
  @PUBLIC_BIND_LINE@
@SEC_NO_LIMIT@
    @EDGE_GATE@
    tls {
      dns cloudflare {env.CF_API_TOKEN}
      resolvers 1.1.1.1 8.8.8.8
      propagation_delay 30s
      propagation_timeout 5m
    }
    header X-Edge-Fallback "1"
    header X-Edge-Route "catch-all"
    # redir sorts before forward_auth: keep it inside a handle so the gate runs first.
    handle {
      redir @CATCH_REDIRECT@ 302
    }
  }
