  # Same posture as (security) with a dedicated rate-limit zone for the JMAP
  # vhost. A syncing mail client legitimately bursts far past 100 req/min
  # (Email/query paging + Email/get batches + per-op Email/set), and the
  # shared global zone throttled it the same way it starved MCP session
  # starts (see 12e9766e / (security_mcp)).
  (security_jmap) {
    import security_headers
    # The webmail (browser, webmail.<domain>) calls JMAP cross-origin WITH the Authelia session cookie
    # that the edge gate reads: credentialed CORS needs one explicit origin (never `*`), the
    # credentials flag, and X-Fleet-Authorization allowed for fleet-token clients that preflight.
    header {
      Access-Control-Allow-Origin "https://webmail.diegonmarcos.com"
      Access-Control-Allow-Credentials "true"
      Access-Control-Allow-Headers "Authorization, Content-Type, X-Fleet-Authorization"
      Vary Origin
    }
    import block_bots
    import block_scanners
    import rate_limiting_jmap
    import ip_block
    import access_log
  }
