  # Same posture as (security) with a dedicated rate-limit zone for the JMAP
  # vhost. A syncing mail client legitimately bursts far past 100 req/min
  # (Email/query paging + Email/get batches + per-op Email/set), and the
  # shared global zone throttled it the same way it starved MCP session
  # starts (see 12e9766e / (security_mcp)).
  (security_jmap) {
    import security_headers
    import block_bots
    import block_scanners
    import rate_limiting_jmap
    import ip_block
    import access_log
  }
